#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Hybrid App — Infrastructure Asset Tracker Teardown Script
#
# This script reverses the Hybrid App deployment, deleting all resources in the
# correct reverse dependency order:
#   Phase 1: Delete application namespace in guest cluster
#            (removes Frontend + API Deployments, Services)
#   Phase 2: Delete VirtualMachine in supervisor namespace
#            (waits for VM termination within timeout)
#
# Uses the same environment variables as the deploy script.
# Run: bash examples/deploy-hybrid-app/teardown-hybrid-app.sh
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

# --- VM Configuration ---
VM_NAME="${VM_NAME:-postgresql-vm}"

# --- Application Namespace ---
APP_NAMESPACE="${APP_NAMESPACE:-hybrid-app}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Resource Status Tracking
###############################################################################

declare -A RESOURCE_STATUS
RESOURCE_STATUS=(
  ["namespace"]="not attempted"
  ["virtualmachine"]="not attempted"
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
# Phase 1: Delete Application Namespace in Guest Cluster
#   (deletes Frontend + API Deployments, Services, and namespace)
###############################################################################

log_step 1 "Deleting application namespace '${APP_NAMESPACE}' in guest cluster"

if [[ -f "${KUBECONFIG_FILE}" ]]; then
  export KUBECONFIG="${KUBECONFIG_FILE}"

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
# Phase 2: Delete VirtualMachine in Supervisor Namespace
###############################################################################

log_step 2 "Deleting VirtualMachine '${VM_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

# Ensure VCF CLI context exists for supervisor operations
if [[ -n "${CONTEXT_NAME}" ]]; then
  if ! vcf context use "${CONTEXT_NAME}" 2>/dev/null; then
    vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true
    vcf context create "${CONTEXT_NAME}" \
      --endpoint "https://${VCFA_ENDPOINT}" \
      --type cci \
      --tenant-name "${TENANT_NAME}" \
      --api-token "${VCF_API_TOKEN}" \
      --set-current 2>/dev/null || true
  fi

  # Switch to the namespace-level context for supervisor operations
  if [[ -n "${SUPERVISOR_NAMESPACE}" ]]; then
    NAMESPACE_CONTEXT=$(vcf context list 2>&1 | grep "${CONTEXT_NAME}:.*${SUPERVISOR_NAMESPACE}" | awk '{print $1}' | head -1 || true)
    if [[ -n "${NAMESPACE_CONTEXT}" ]]; then
      vcf context use "${NAMESPACE_CONTEXT}" 2>/dev/null || true
    fi
  fi
fi

if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "VirtualMachine '${VM_NAME}' delete command issued"

    # Wait for VM to be fully terminated
    if wait_for_deletion "VirtualMachine '${VM_NAME}'" \
      "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
      "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}'"; then
      log_success "VirtualMachine '${VM_NAME}' fully terminated"
      RESOURCE_STATUS["virtualmachine"]="deleted"
    else
      log_warn "VirtualMachine '${VM_NAME}' was not fully terminated within ${VM_TIMEOUT}s — it may still be deleting"
      RESOURCE_STATUS["virtualmachine"]="failed"
    fi
  else
    log_warn "Failed to delete VirtualMachine '${VM_NAME}' — continuing"
    RESOURCE_STATUS["virtualmachine"]="failed"
  fi
else
  log_success "VirtualMachine '${VM_NAME}' does not exist, already absent"
  RESOURCE_STATUS["virtualmachine"]="already absent"
fi

# Clean up cloud-init Secret
kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
log_success "Cloud-init Secret '${VM_NAME}-cloud-init' cleaned up"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Hybrid App — Teardown Complete"
echo "============================================="
echo "  Cluster:        ${CLUSTER_NAME}"
echo "  Namespace:      ${APP_NAMESPACE} (${RESOURCE_STATUS["namespace"]})"
echo "  VirtualMachine: ${VM_NAME} (${RESOURCE_STATUS["virtualmachine"]})"
echo "============================================="
echo ""

exit 0
