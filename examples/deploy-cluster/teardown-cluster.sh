#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Cluster — Full Stack Teardown Script
#
# This script reverses the full-stack deploy, deleting all resources in the
# correct dependency order:
#   Phase 1: Guest Cluster Workload Cleanup (Service, Deployment, PVC)
#   Phase 2: VKS Cluster Deletion
#   Phase 3: Supervisor Namespace + RBAC + Project Deletion
#   Phase 4: VCF CLI Context & Local Artifact Cleanup
#
# Uses the same .env / environment variables as the deploy script.
# Run: bash examples/deploy-cluster/teardown-cluster.sh
###############################################################################

###############################################################################
# Variable Block — Same as deploy script
###############################################################################

# --- API Token ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"

# --- VCFA Connection ---
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Project & Namespace ---
PROJECT_NAME="${PROJECT_NAME:-}"
USER_IDENTITY="${USER_IDENTITY:-}"

# --- VKS Cluster ---
CLUSTER_NAME="${CLUSTER_NAME:-}"

# --- Timeouts and Polling ---
CLUSTER_DELETE_TIMEOUT="${CLUSTER_DELETE_TIMEOUT:-1800}"
NS_DELETE_TIMEOUT="${NS_DELETE_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

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
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "PROJECT_NAME"
    "USER_IDENTITY"
    "CLUSTER_NAME"
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
# Phase 0: Ensure VCF CLI Context Exists and Discover Namespace
###############################################################################

log_step 0 "Establishing VCF CLI context"

# Ensure context exists — try to activate, create only if needed
if ! vcf context use "${CONTEXT_NAME}" 2>/dev/null; then
  vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
  if ! vcf context create "${CONTEXT_NAME}" \
    --endpoint "https://${VCFA_ENDPOINT}" \
    --type cci \
    --tenant-name "${TENANT_NAME}" \
    --api-token "${VCF_API_TOKEN}"; then
    log_error "Failed to create VCF CLI context '${CONTEXT_NAME}'"
    exit 2
  fi
  vcf context use "${CONTEXT_NAME}"
fi

log_success "VCF CLI context '${CONTEXT_NAME}' active"

# Discover the dynamic namespace name
DYNAMIC_NS_NAME=$(kubectl get supervisornamespaces -n "${PROJECT_NAME}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "${DYNAMIC_NS_NAME}" ]]; then
  log_warn "No SupervisorNamespace found in project '${PROJECT_NAME}' — skipping cluster and workload teardown"
  SKIP_CLUSTER_TEARDOWN=true
else
  SKIP_CLUSTER_TEARDOWN=false
  log_success "Discovered namespace '${DYNAMIC_NS_NAME}' in project '${PROJECT_NAME}'"
fi

###############################################################################
# Phase 1: Guest Cluster Workload Cleanup
###############################################################################

if [[ "${SKIP_CLUSTER_TEARDOWN}" == "false" ]]; then

  KUBECONFIG_FILE="./kubeconfig-${CLUSTER_NAME}.yaml"

  # Try to get admin kubeconfig for the guest cluster
  if vcf context use "${CONTEXT_NAME}:${DYNAMIC_NS_NAME}:${PROJECT_NAME}" 2>/dev/null; then

    # Wait for namespace-scoped plugins (e.g. cluster) to install
    PLUGIN_WAIT=0
    PLUGIN_MAX=60
    while [[ "${PLUGIN_WAIT}" -lt "${PLUGIN_MAX}" ]]; do
      if vcf cluster --help >/dev/null 2>&1; then
        break
      fi
      echo "  Waiting for VCF CLI plugins to install... (${PLUGIN_WAIT}s/${PLUGIN_MAX}s)"
      sleep 5
      PLUGIN_WAIT=$((PLUGIN_WAIT + 5))
    done
  fi

  if vcf cluster kubeconfig get "${CLUSTER_NAME}" --admin --export-file "${KUBECONFIG_FILE}" 2>/dev/null; then

    log_step 1 "Deleting guest cluster workloads (Service, Deployment, PVC)"

    export KUBECONFIG="${KUBECONFIG_FILE}"

    kubectl delete svc vks-test-lb --ignore-not-found 2>/dev/null || true
    kubectl delete deployment vks-test-app --ignore-not-found 2>/dev/null || true
    kubectl delete pvc vks-test-pvc --ignore-not-found 2>/dev/null || true

    log_success "Guest cluster workloads deleted"

    # Unset so subsequent kubectl commands use the VCF CLI context
    unset KUBECONFIG
  else
    log_warn "Could not retrieve guest cluster kubeconfig — skipping workload cleanup"
  fi

  ##############################################################################
  # Phase 2: VKS Cluster Deletion
  ##############################################################################

  log_step 2 "Deleting VKS cluster '${CLUSTER_NAME}'"

  # Switch to namespace-scoped context for cluster operations
  if vcf context use "${CONTEXT_NAME}:${DYNAMIC_NS_NAME}:${PROJECT_NAME}" 2>/dev/null; then

    # Wait for namespace-scoped plugins (e.g. cluster) to install
    PLUGIN_WAIT=0
    PLUGIN_MAX=60
    while [[ "${PLUGIN_WAIT}" -lt "${PLUGIN_MAX}" ]]; do
      if vcf cluster --help >/dev/null 2>&1; then
        break
      fi
      echo "  Waiting for VCF CLI plugins to install... (${PLUGIN_WAIT}s/${PLUGIN_MAX}s)"
      sleep 5
      PLUGIN_WAIT=$((PLUGIN_WAIT + 5))
    done

    if kubectl get cluster "${CLUSTER_NAME}" -n "${DYNAMIC_NS_NAME}" 2>/dev/null; then
      kubectl delete cluster "${CLUSTER_NAME}" -n "${DYNAMIC_NS_NAME}"

      if ! wait_for_deletion "VKS cluster '${CLUSTER_NAME}'" \
        "${CLUSTER_DELETE_TIMEOUT}" "${POLL_INTERVAL}" \
        "kubectl get cluster '${CLUSTER_NAME}' -n '${DYNAMIC_NS_NAME}'"; then
        log_error "Cluster '${CLUSTER_NAME}' was not fully deleted within ${CLUSTER_DELETE_TIMEOUT}s"
        exit 3
      fi

      log_success "VKS cluster '${CLUSTER_NAME}' deleted"
    else
      log_success "Cluster '${CLUSTER_NAME}' does not exist, nothing to delete"
    fi
  else
    log_warn "Could not switch to namespace context — skipping cluster deletion"
  fi

  # Switch back to project-level context
  vcf context use "${CONTEXT_NAME}" 2>/dev/null || true
fi

###############################################################################
# Phase 3: Supervisor Namespace + RBAC + Project Deletion
###############################################################################

log_step 3 "Deleting Supervisor Namespace, ProjectRoleBinding, and Project"

# Ensure we're on the project-level context
vcf context use "${CONTEXT_NAME}" 2>/dev/null || true

# Delete SupervisorNamespace (if it exists)
if [[ "${SKIP_CLUSTER_TEARDOWN}" == "false" && -n "${DYNAMIC_NS_NAME}" ]]; then
  if kubectl get supervisornamespace "${DYNAMIC_NS_NAME}" -n "${PROJECT_NAME}" 2>/dev/null; then
    kubectl delete supervisornamespace "${DYNAMIC_NS_NAME}" -n "${PROJECT_NAME}"

    if ! wait_for_deletion "SupervisorNamespace '${DYNAMIC_NS_NAME}'" \
      "${NS_DELETE_TIMEOUT}" "${POLL_INTERVAL}" \
      "kubectl get supervisornamespace '${DYNAMIC_NS_NAME}' -n '${PROJECT_NAME}'"; then
      log_warn "SupervisorNamespace '${DYNAMIC_NS_NAME}' was not fully deleted within ${NS_DELETE_TIMEOUT}s — continuing anyway"
    else
      log_success "SupervisorNamespace '${DYNAMIC_NS_NAME}' deleted"
    fi
  else
    log_success "SupervisorNamespace '${DYNAMIC_NS_NAME}' does not exist, nothing to delete"
  fi
fi

# Delete ProjectRoleBinding
kubectl delete projectrolebinding "cci:user:${USER_IDENTITY}" -n "${PROJECT_NAME}" --ignore-not-found 2>/dev/null || true
log_success "ProjectRoleBinding 'cci:user:${USER_IDENTITY}' deleted"

# Delete Project
kubectl delete project "${PROJECT_NAME}" --ignore-not-found 2>/dev/null || true
log_success "Project '${PROJECT_NAME}' deleted"

###############################################################################
# Phase 4: VCF CLI Context & Local Artifact Cleanup
###############################################################################

log_step 4 "Cleaning up VCF CLI context and local artifacts"

vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
log_success "VCF CLI context '${CONTEXT_NAME}' deleted"

# Remove local kubeconfig file
KUBECONFIG_FILE="./kubeconfig-${CLUSTER_NAME}.yaml"
if [[ -f "${KUBECONFIG_FILE}" ]]; then
  rm -f "${KUBECONFIG_FILE}"
  log_success "Local kubeconfig '${KUBECONFIG_FILE}' removed"
fi

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Cluster — Teardown Complete"
echo "============================================="
echo "  Cluster:    ${CLUSTER_NAME} (deleted)"
echo "  Project:    ${PROJECT_NAME} (deleted)"
if [[ -n "${DYNAMIC_NS_NAME:-}" ]]; then
echo "  Namespace:  ${DYNAMIC_NS_NAME} (deleted)"
fi
echo "  Context:    ${CONTEXT_NAME} (deleted)"
echo "============================================="
echo ""

exit 0
