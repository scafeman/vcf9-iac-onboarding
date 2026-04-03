#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy HA VM App — High-Availability Three-Tier Application Teardown
#
# This script reverses the HA VM App deployment, deleting all resources in the
# correct reverse dependency order:
#   Phase 1: Delete ha-web-lb VirtualMachineService (releases LoadBalancer IP)
#   Phase 2: Delete web-vm-01 / web-vm-02 VirtualMachines + cloud-init secrets
#   Phase 3: Delete ha-api-internal VirtualMachineService
#   Phase 4: Delete api-vm-01 / api-vm-02 VirtualMachines + cloud-init secrets
#   Phase 5: Delete DSM PostgresCluster + admin password secret
#
# Uses the same environment variables as the deploy script.
# Run: bash examples/deploy-ha-vm-app/teardown-ha-vm-app.sh
###############################################################################

###############################################################################
# Variable Block — Same as deploy script
###############################################################################

# --- VCF CLI Connection ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Supervisor Namespace ---
SUPERVISOR_NAMESPACE="${SUPERVISOR_NAMESPACE:-}"

# --- Cluster Name (used for namespace context fallback) ---
CLUSTER_NAME="${CLUSTER_NAME:-}"

# --- DSM PostgresCluster Configuration ---
DSM_CLUSTER_NAME="${DSM_CLUSTER_NAME:-postgres-clus-01}"
ADMIN_PASSWORD_SECRET_NAME="${ADMIN_PASSWORD_SECRET_NAME:-admin-pw-pg-clus-01}"

# --- VM Names ---
API_VM_01_NAME="${API_VM_01_NAME:-api-vm-01}"
API_VM_02_NAME="${API_VM_02_NAME:-api-vm-02}"
WEB_VM_01_NAME="${WEB_VM_01_NAME:-web-vm-01}"
WEB_VM_02_NAME="${WEB_VM_02_NAME:-web-vm-02}"

# --- Service Names ---
WEB_LB_NAME="${WEB_LB_NAME:-ha-web-lb}"
API_SVC_NAME="${API_SVC_NAME:-ha-api-lb}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Resource Status Tracking
###############################################################################

declare -A RESOURCE_STATUS
RESOURCE_STATUS=(
  ["${WEB_LB_NAME}"]="not attempted"
  ["${WEB_VM_01_NAME}"]="not attempted"
  ["${WEB_VM_01_NAME}-cloud-init"]="not attempted"
  ["${WEB_VM_02_NAME}"]="not attempted"
  ["${WEB_VM_02_NAME}-cloud-init"]="not attempted"
  ["${API_SVC_NAME}"]="not attempted"
  ["${API_VM_01_NAME}"]="not attempted"
  ["${API_VM_01_NAME}-cloud-init"]="not attempted"
  ["${API_VM_02_NAME}"]="not attempted"
  ["${API_VM_02_NAME}-cloud-init"]="not attempted"
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
  PROJECT_PATTERN=$(echo "${CLUSTER_NAME:-${SUPERVISOR_NAMESPACE}}" | sed 's/-clus-[0-9]*$//')
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
# Phase 1: Delete Web Tier VirtualMachineService LoadBalancer
###############################################################################

log_step 1 "Deleting VirtualMachineService '${WEB_LB_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get virtualmachineservice "${WEB_LB_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete virtualmachineservice "${WEB_LB_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "VirtualMachineService '${WEB_LB_NAME}' deleted"
    RESOURCE_STATUS["${WEB_LB_NAME}"]="deleted"
  else
    log_warn "Failed to delete VirtualMachineService '${WEB_LB_NAME}' — continuing with remaining teardown"
    RESOURCE_STATUS["${WEB_LB_NAME}"]="failed"
  fi
else
  log_success "VirtualMachineService '${WEB_LB_NAME}' does not exist, already absent"
  RESOURCE_STATUS["${WEB_LB_NAME}"]="already absent"
fi

###############################################################################
# Phase 2: Delete Web Tier VMs + Cloud-Init Secrets
###############################################################################

for VM_NAME in "${WEB_VM_01_NAME}" "${WEB_VM_02_NAME}"; do
  log_step 2 "Deleting VirtualMachine '${VM_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

  if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    if kubectl delete virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
      log_success "VirtualMachine '${VM_NAME}' delete command issued"

      # Wait for VM to be fully terminated
      if wait_for_deletion "VirtualMachine '${VM_NAME}'" \
        "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
        "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}'"; then
        log_success "VirtualMachine '${VM_NAME}' fully terminated"
        RESOURCE_STATUS["${VM_NAME}"]="deleted"
      else
        log_warn "VirtualMachine '${VM_NAME}' was not fully terminated within ${VM_TIMEOUT}s — it may still be deleting"
        RESOURCE_STATUS["${VM_NAME}"]="failed"
      fi
    else
      log_warn "Failed to delete VirtualMachine '${VM_NAME}' — continuing"
      RESOURCE_STATUS["${VM_NAME}"]="failed"
    fi
  else
    log_success "VirtualMachine '${VM_NAME}' does not exist, already absent"
    RESOURCE_STATUS["${VM_NAME}"]="already absent"
  fi

  # Delete cloud-init secret
  log_step 2 "Deleting cloud-init Secret '${VM_NAME}-cloud-init' in namespace '${SUPERVISOR_NAMESPACE}'"

  if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    if kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
      log_success "Secret '${VM_NAME}-cloud-init' deleted"
      RESOURCE_STATUS["${VM_NAME}-cloud-init"]="deleted"
    else
      log_warn "Failed to delete Secret '${VM_NAME}-cloud-init' — continuing"
      RESOURCE_STATUS["${VM_NAME}-cloud-init"]="failed"
    fi
  else
    log_success "Secret '${VM_NAME}-cloud-init' does not exist, already absent"
    RESOURCE_STATUS["${VM_NAME}-cloud-init"]="already absent"
  fi
done

###############################################################################
# Phase 3: Delete API Tier VirtualMachineService
###############################################################################

log_step 3 "Deleting VirtualMachineService '${API_SVC_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get virtualmachineservice "${API_SVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete virtualmachineservice "${API_SVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "VirtualMachineService '${API_SVC_NAME}' deleted"
    RESOURCE_STATUS["${API_SVC_NAME}"]="deleted"
  else
    log_warn "Failed to delete VirtualMachineService '${API_SVC_NAME}' — continuing with remaining teardown"
    RESOURCE_STATUS["${API_SVC_NAME}"]="failed"
  fi
else
  log_success "VirtualMachineService '${API_SVC_NAME}' does not exist, already absent"
  RESOURCE_STATUS["${API_SVC_NAME}"]="already absent"
fi

###############################################################################
# Phase 4: Delete API Tier VMs + Cloud-Init Secrets
###############################################################################

for VM_NAME in "${API_VM_01_NAME}" "${API_VM_02_NAME}"; do
  log_step 4 "Deleting VirtualMachine '${VM_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

  if kubectl get virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    if kubectl delete virtualmachine "${VM_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
      log_success "VirtualMachine '${VM_NAME}' delete command issued"

      # Wait for VM to be fully terminated
      if wait_for_deletion "VirtualMachine '${VM_NAME}'" \
        "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
        "kubectl get virtualmachine '${VM_NAME}' -n '${SUPERVISOR_NAMESPACE}'"; then
        log_success "VirtualMachine '${VM_NAME}' fully terminated"
        RESOURCE_STATUS["${VM_NAME}"]="deleted"
      else
        log_warn "VirtualMachine '${VM_NAME}' was not fully terminated within ${VM_TIMEOUT}s — it may still be deleting"
        RESOURCE_STATUS["${VM_NAME}"]="failed"
      fi
    else
      log_warn "Failed to delete VirtualMachine '${VM_NAME}' — continuing"
      RESOURCE_STATUS["${VM_NAME}"]="failed"
    fi
  else
    log_success "VirtualMachine '${VM_NAME}' does not exist, already absent"
    RESOURCE_STATUS["${VM_NAME}"]="already absent"
  fi

  # Delete cloud-init secret
  log_step 4 "Deleting cloud-init Secret '${VM_NAME}-cloud-init' in namespace '${SUPERVISOR_NAMESPACE}'"

  if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
    if kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
      log_success "Secret '${VM_NAME}-cloud-init' deleted"
      RESOURCE_STATUS["${VM_NAME}-cloud-init"]="deleted"
    else
      log_warn "Failed to delete Secret '${VM_NAME}-cloud-init' — continuing"
      RESOURCE_STATUS["${VM_NAME}-cloud-init"]="failed"
    fi
  else
    log_success "Secret '${VM_NAME}-cloud-init' does not exist, already absent"
    RESOURCE_STATUS["${VM_NAME}-cloud-init"]="already absent"
  fi
done

###############################################################################
# Phase 5: Delete DSM PostgresCluster + Admin Password Secret
###############################################################################

log_step 5 "Deleting PostgresCluster '${DSM_CLUSTER_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete postgrescluster "${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found --wait=false; then
    log_success "PostgresCluster '${DSM_CLUSTER_NAME}' delete command issued"

    # Wait for PostgresCluster to be fully deleted
    if wait_for_deletion "PostgresCluster '${DSM_CLUSTER_NAME}'" \
      "${VM_TIMEOUT}" "${POLL_INTERVAL}" \
      "kubectl get postgrescluster '${DSM_CLUSTER_NAME}' -n '${SUPERVISOR_NAMESPACE}'"; then
      log_success "PostgresCluster '${DSM_CLUSTER_NAME}' fully deleted"
      RESOURCE_STATUS["postgrescluster"]="deleted"
    else
      log_warn "PostgresCluster '${DSM_CLUSTER_NAME}' was not fully deleted within ${VM_TIMEOUT}s — it may still be deleting"
      RESOURCE_STATUS["postgrescluster"]="failed"
    fi
  else
    log_warn "Failed to delete PostgresCluster '${DSM_CLUSTER_NAME}' — continuing"
    RESOURCE_STATUS["postgrescluster"]="failed"
  fi
else
  log_success "PostgresCluster '${DSM_CLUSTER_NAME}' does not exist, already absent"
  RESOURCE_STATUS["postgrescluster"]="already absent"
fi

# Clean up DSM-created password secret pg-<cluster-name>
kubectl delete secret "pg-${DSM_CLUSTER_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
log_success "DSM-created Secret 'pg-${DSM_CLUSTER_NAME}' cleaned up"

# Delete admin password secret
log_step 5 "Deleting admin password Secret '${ADMIN_PASSWORD_SECRET_NAME}' in supervisor namespace '${SUPERVISOR_NAMESPACE}'"

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

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 HA VM App — Teardown Complete"
echo "============================================="
echo "  Namespace:          ${SUPERVISOR_NAMESPACE}"
echo "  ${WEB_LB_NAME}:          (${RESOURCE_STATUS["${WEB_LB_NAME}"]})"
echo "  ${WEB_VM_01_NAME}:          (${RESOURCE_STATUS["${WEB_VM_01_NAME}"]})"
echo "  ${WEB_VM_01_NAME}-cloud-init: (${RESOURCE_STATUS["${WEB_VM_01_NAME}-cloud-init"]})"
echo "  ${WEB_VM_02_NAME}:          (${RESOURCE_STATUS["${WEB_VM_02_NAME}"]})"
echo "  ${WEB_VM_02_NAME}-cloud-init: (${RESOURCE_STATUS["${WEB_VM_02_NAME}-cloud-init"]})"
echo "  ${API_SVC_NAME}:    (${RESOURCE_STATUS["${API_SVC_NAME}"]})"
echo "  ${API_VM_01_NAME}:          (${RESOURCE_STATUS["${API_VM_01_NAME}"]})"
echo "  ${API_VM_01_NAME}-cloud-init: (${RESOURCE_STATUS["${API_VM_01_NAME}-cloud-init"]})"
echo "  ${API_VM_02_NAME}:          (${RESOURCE_STATUS["${API_VM_02_NAME}"]})"
echo "  ${API_VM_02_NAME}-cloud-init: (${RESOURCE_STATUS["${API_VM_02_NAME}-cloud-init"]})"
echo "  PostgresCluster:    ${DSM_CLUSTER_NAME} (${RESOURCE_STATUS["postgrescluster"]})"
echo "  Admin Secret:       ${ADMIN_PASSWORD_SECRET_NAME} (${RESOURCE_STATUS["admin-password-secret"]})"
echo "============================================="
echo ""

exit 0
