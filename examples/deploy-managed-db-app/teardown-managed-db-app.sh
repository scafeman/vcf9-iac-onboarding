#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Managed DB App — Infrastructure Asset Tracker Teardown Script
#
# This script reverses the Managed DB App deployment, deleting all resources in
# the correct reverse dependency order:
#   Phase 1: Delete application namespace in guest cluster
#            (removes Frontend + API Deployments, Services)
#   Phase 2: Delete PostgresCluster in supervisor namespace
#            (waits for deletion within timeout)
#   Phase 3: Delete admin password Secret in supervisor namespace
#
# Uses the same environment variables as the deploy script.
# Run: bash examples/deploy-managed-db-app/teardown-managed-db-app.sh
###############################################################################

###############################################################################
# Variable Block — Same as deploy script
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

# --- DSM PostgresCluster Configuration ---
DSM_CLUSTER_NAME="${DSM_CLUSTER_NAME:-postgres-clus-01}"
ADMIN_PASSWORD_SECRET_NAME="${ADMIN_PASSWORD_SECRET_NAME:-postgres-admin-password}"

# --- Application Namespace ---
APP_NAMESPACE="${APP_NAMESPACE:-managed-db-app}"

# --- Timeouts and Polling ---
DSM_TIMEOUT="${DSM_TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Resource Status Tracking
###############################################################################

declare -A RESOURCE_STATUS
RESOURCE_STATUS=(
  ["namespace"]="not attempted"
  ["postgrescluster"]="not attempted"
  ["admin-password-secret"]="not attempted"
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

log_warn() {
  echo "⚠ WARNING: $1"
}

log_error() {
  echo "✗ ERROR: $1" >&2
}

validate_variables() {
  local missing=0
  local required_vars=(
    "CLUSTER_NAME"
    "SUPERVISOR_NAMESPACE"
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
  )

  for var_name in "${required_vars[@]}"; do
    if [[ -z "${!var_name:-}" ]]; then
      log_error "Required variable ${var_name} is not set or is empty"
      missing=1
    fi
  done

  if [[ "${missing}" -eq 1 ]]; then
    log_error "One or more required variables are missing."
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
  PROJECT_PATTERN=$(echo "${CLUSTER_NAME}" | sed 's/-clus-[0-9]*$//')
  NS_CTX=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${PROJECT_PATTERN}" | awk '{print $1}' | head -1 || true)
fi

if [[ -n "${NS_CTX}" ]]; then
  vcf context use "${NS_CTX}" >/dev/null 2>&1 || true
  log_success "VCF CLI context '${CONTEXT_NAME}' created, switched to namespace context '${NS_CTX}'"
else
  log_warn "Could not find namespace context for '${SUPERVISOR_NAMESPACE}' — supervisor operations may fail"
  log_success "VCF CLI context '${CONTEXT_NAME}' created"
fi

###############################################################################
# Phase 1: Delete Application Namespace in Guest Cluster
#   (deletes Frontend + API Deployments, Services, and namespace)
###############################################################################

log_step 1 "Deleting application namespace '${APP_NAMESPACE}' in guest cluster"

# If kubeconfig doesn't exist, try to retrieve it via VCF CLI
if [[ ! -f "${KUBECONFIG_FILE}" ]] && [[ -n "${CLUSTER_NAME}" ]]; then
  log_warn "Kubeconfig not found at '${KUBECONFIG_FILE}', attempting retrieval via VCF CLI..."
  vcf cluster kubeconfig get "${CLUSTER_NAME}" --admin --export-file "${KUBECONFIG_FILE}" 2>/dev/null || true
fi

if [[ -f "${KUBECONFIG_FILE}" ]]; then
  export KUBECONFIG="${KUBECONFIG_FILE}"

  # Switch to admin context
  ADMIN_CONTEXT="${CLUSTER_NAME}-admin@${CLUSTER_NAME}"
  kubectl config use-context "${ADMIN_CONTEXT}" --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null || \
    kubectl config use-context "$(kubectl config get-contexts -o name --kubeconfig="${KUBECONFIG_FILE}" | head -1)" --kubeconfig="${KUBECONFIG_FILE}" 2>/dev/null || true

  if kubectl get ns "${APP_NAMESPACE}" >/dev/null 2>&1; then
    if kubectl delete ns "${APP_NAMESPACE}" --ignore-not-found; then
      log_success "Namespace '${APP_NAMESPACE}' deleted (includes Frontend + API Deployments and Services)"
      RESOURCE_STATUS["namespace"]="deleted"
    else
      log_warn "Failed to delete namespace '${APP_NAMESPACE}' — continuing with remaining teardown"
      RESOURCE_STATUS["namespace"]="failed"
    fi
  else
    log_success "Namespace '${APP_NAMESPACE}' does not exist, already absent"
    RESOURCE_STATUS["namespace"]="already absent"
  fi

  unset KUBECONFIG
else
  log_warn "Guest cluster kubeconfig not found at '${KUBECONFIG_FILE}' — skipping guest cluster cleanup"
  RESOURCE_STATUS["namespace"]="failed"
fi

###############################################################################
# Phase 2: Delete PostgresCluster in Supervisor Namespace
###############################################################################

log_step 2 "Deleting PostgresCluster '${DSM_CLUSTER_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Unset guest cluster kubeconfig so kubectl uses VCF CLI context for supervisor operations
unset KUBECONFIG 2>/dev/null || true

if kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  # Issue delete (non-blocking with --wait=false to avoid hanging on finalizers)
  if kubectl delete postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found --wait=false; then
    log_success "PostgresCluster '${DSM_CLUSTER_NAME}' delete command issued"

    # Wait for PostgresCluster to be fully deleted
    if wait_for_deletion "PostgresCluster '${DSM_CLUSTER_NAME}'" \
      "${DSM_TIMEOUT}" "${POLL_INTERVAL}" \
      "kubectl get postgrescluster '${DSM_CLUSTER_NAME}' -n '${SUPERVISOR_NAMESPACE}'"; then
      log_success "PostgresCluster '${DSM_CLUSTER_NAME}' fully deleted"
      RESOURCE_STATUS["postgrescluster"]="deleted"
    else
      # Fallback: strip finalizer if deletion is stuck (e.g., PV cleanup failure)
      log_warn "PostgresCluster '${DSM_CLUSTER_NAME}' stuck in Deleting — stripping finalizer"
      kubectl patch postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" \
        --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      sleep 5
      if ! kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
        log_success "PostgresCluster '${DSM_CLUSTER_NAME}' deleted after finalizer removal"
        RESOURCE_STATUS["postgrescluster"]="deleted"
      else
        log_warn "PostgresCluster '${DSM_CLUSTER_NAME}' still exists after finalizer removal"
        RESOURCE_STATUS["postgrescluster"]="failed"
      fi
    fi
  else
    log_warn "Failed to delete PostgresCluster '${DSM_CLUSTER_NAME}' — continuing"
    RESOURCE_STATUS["postgrescluster"]="failed"
  fi
else
  log_success "PostgresCluster '${DSM_CLUSTER_NAME}' does not exist, already absent"
  RESOURCE_STATUS["postgrescluster"]="already absent"
fi

###############################################################################
# Phase 3: Delete Admin Password Secret in Supervisor Namespace
###############################################################################

log_step 3 "Deleting admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get secret "${ADMIN_PASSWORD_SECRET_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete secret "${ADMIN_PASSWORD_SECRET_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "Admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' deleted"
    RESOURCE_STATUS["admin-password-secret"]="deleted"
  else
    log_warn "Failed to delete admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' — continuing"
    RESOURCE_STATUS["admin-password-secret"]="failed"
  fi
else
  log_success "Admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' does not exist, already absent"
  RESOURCE_STATUS["admin-password-secret"]="already absent"
fi

# Clean up DSM-created password secret pg-<cluster-name>
kubectl delete secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
log_success "DSM-created Secret 'pg-${DSM_CLUSTER_NAME}' cleaned up"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Managed DB App — Teardown Complete"
echo "============================================="
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  Namespace:        ${APP_NAMESPACE} (${RESOURCE_STATUS["namespace"]})"
echo "  PostgresCluster:  ${DSM_CLUSTER_NAME} (${RESOURCE_STATUS["postgrescluster"]})"
echo "  Admin Secret:     ${ADMIN_PASSWORD_SECRET_NAME} (${RESOURCE_STATUS["admin-password-secret"]})"
echo "============================================="
echo ""

exit 0
