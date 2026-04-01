#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Bastion VM — SSH Jump Host Teardown Script
#
# This script reverses the Bastion VM deployment, deleting all resources in the
# correct reverse dependency order:
#   Phase 1: Delete VirtualMachineService (releases LoadBalancer IP)
#   Phase 2: Delete VirtualMachine (wait for termination)
#   Phase 3: Delete Data Disk PVC (if exists)
#   Phase 4: Delete cloud-init Secret
#
# Uses the same environment variables as the deploy script.
# Run: bash examples/deploy-bastion-vm/teardown-bastion-vm.sh
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

# --- VM Configuration ---
VM_NAME="${VM_NAME:-bastion-vm}"

# --- Timeouts and Polling ---
VM_TIMEOUT="${VM_TIMEOUT:-600}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"

###############################################################################
# Resource Status Tracking
###############################################################################

declare -A RESOURCE_STATUS
RESOURCE_STATUS=(
  ["vmservice"]="not attempted"
  ["virtualmachine"]="not attempted"
  ["data-pvc"]="not attempted"
  ["cloud-init-secret"]="not attempted"
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
# Phase 1: Delete VirtualMachineService
###############################################################################

VMSERVICE_NAME="${VM_NAME}-ssh"

log_step 1 "Deleting VirtualMachineService '${VMSERVICE_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get virtualmachineservice "${VMSERVICE_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete virtualmachineservice "${VMSERVICE_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "VirtualMachineService '${VMSERVICE_NAME}' deleted"
    RESOURCE_STATUS["vmservice"]="deleted"
  else
    log_warn "Failed to delete VirtualMachineService '${VMSERVICE_NAME}' — continuing with remaining teardown"
    RESOURCE_STATUS["vmservice"]="failed"
  fi
else
  log_success "VirtualMachineService '${VMSERVICE_NAME}' does not exist, already absent"
  RESOURCE_STATUS["vmservice"]="already absent"
fi

###############################################################################
# Phase 2: Delete VirtualMachine
###############################################################################

log_step 2 "Deleting VirtualMachine '${VM_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

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

###############################################################################
# Phase 3: Delete Data Disk PVC (if exists)
###############################################################################

DATA_PVC_NAME="${VM_NAME}-data"

log_step 3 "Deleting data disk PVC '${DATA_PVC_NAME}' in namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get pvc "${DATA_PVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  # Strip finalizer if stuck
  kubectl patch pvc "${DATA_PVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" \
    --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  if kubectl delete pvc "${DATA_PVC_NAME}" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "PVC '${DATA_PVC_NAME}' deleted"
    RESOURCE_STATUS["data-pvc"]="deleted"
  else
    log_warn "Failed to delete PVC '${DATA_PVC_NAME}' — continuing"
    RESOURCE_STATUS["data-pvc"]="failed"
  fi
else
  log_success "PVC '${DATA_PVC_NAME}' does not exist, already absent"
  RESOURCE_STATUS["data-pvc"]="already absent"
fi

###############################################################################
# Phase 4: Delete Cloud-Init Secret
###############################################################################

log_step 4 "Deleting cloud-init Secret '${VM_NAME}-cloud-init' in namespace '${SUPERVISOR_NAMESPACE}'"

if kubectl get secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" >/dev/null 2>&1; then
  if kubectl delete secret "${VM_NAME}-cloud-init" -n "${SUPERVISOR_NAMESPACE}" --ignore-not-found; then
    log_success "Secret '${VM_NAME}-cloud-init' deleted"
    RESOURCE_STATUS["cloud-init-secret"]="deleted"
  else
    log_warn "Failed to delete Secret '${VM_NAME}-cloud-init' — continuing"
    RESOURCE_STATUS["cloud-init-secret"]="failed"
  fi
else
  log_success "Secret '${VM_NAME}-cloud-init' does not exist, already absent"
  RESOURCE_STATUS["cloud-init-secret"]="already absent"
fi

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Bastion VM — Teardown Complete"
echo "============================================="
echo "  VM Name:            ${VM_NAME}"
echo "  Namespace:          ${SUPERVISOR_NAMESPACE}"
echo "  VMService:          ${VMSERVICE_NAME} (${RESOURCE_STATUS["vmservice"]})"
echo "  VirtualMachine:     ${VM_NAME} (${RESOURCE_STATUS["virtualmachine"]})"
echo "  Data Disk PVC:      ${VM_NAME}-data (${RESOURCE_STATUS["data-pvc"]})"
echo "  Cloud-Init Secret:  ${VM_NAME}-cloud-init (${RESOURCE_STATUS["cloud-init-secret"]})"
echo "============================================="
echo ""

exit 0
