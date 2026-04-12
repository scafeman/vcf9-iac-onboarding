#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Secrets Demo — Teardown Script
#
# This script reverses the secrets demo deployment, deleting all resources
# in the correct dependency order:
#   Phase 1: Guest Cluster Namespace Cleanup
#   Phase 2: Guest Cluster Cluster-Scoped Resource Cleanup
#   Phase 3: Supervisor Namespace Resource Cleanup
#
# Uses the same environment variables as the deploy script.
# Run: bash examples/deploy-secrets-demo/teardown-secrets-demo.sh
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

# --- Namespace ---
NAMESPACE="${NAMESPACE:-secrets-demo}"

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

###############################################################################
# Phase 1: Delete vault-injector package (must happen before namespace deletion)
###############################################################################

log_step 1 "Deleting vault-injector package"

if [[ -f "${KUBECONFIG_FILE}" ]]; then
  export KUBECONFIG="${KUBECONFIG_FILE}"

  # Check if managed-db-app is still using the vault-injector (shared resource)
  VAULT_DEPS=0
  if kubectl get ns managed-db-app >/dev/null 2>&1; then
    VAULT_DEPS=1
    log_warn "Namespace 'managed-db-app' still exists — skipping vault-injector deletion (shared resource)"
  fi

  if [[ "${VAULT_DEPS}" -eq 0 ]]; then
    if vcf package installed list -n tkg-packages 2>/dev/null | grep -q "vault-injector"; then
      # Strip finalizers first to prevent stuck "Deletion failed" state
      kubectl patch packageinstall vault-injector -n tkg-packages --type merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      kubectl patch app vault-injector -n tkg-packages --type merge \
        -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
      vcf package installed delete vault-injector -n tkg-packages --yes 2>/dev/null || true
      # Clean up any remaining resources
      kubectl delete packageinstall vault-injector -n tkg-packages --ignore-not-found 2>/dev/null || true
      kubectl delete app vault-injector -n tkg-packages --ignore-not-found 2>/dev/null || true
      log_success "vault-injector package deleted"
    else
      log_success "vault-injector package not installed, skipping"
    fi
  fi  # end VAULT_DEPS check

  ###########################################################################
  # Phase 2: Delete namespace and cluster-scoped resources
  ###########################################################################

  log_step 2 "Deleting secrets-demo namespace and cluster-scoped resources"

  # Delete sslip.io Ingress and Certificate resources
  kubectl delete ingress secrets-dashboard-sslip-ingress -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true
  kubectl delete certificate secrets-dashboard-sslip-ingress-tls -n "${NAMESPACE}" --ignore-not-found 2>/dev/null || true

  kubectl delete ns "${NAMESPACE}" --ignore-not-found || true
  log_success "Namespace '${NAMESPACE}' deleted (or already removed by package teardown)"

  # Only delete cluster-scoped vault resources if no other patterns depend on them
  if [[ "${VAULT_DEPS:-0}" -eq 0 ]]; then
    kubectl delete clusterrole vault-injector-clusterrole --ignore-not-found || true
    log_success "ClusterRole 'vault-injector-clusterrole' deleted"

    kubectl delete clusterrolebinding vault-injector-clusterrolebinding --ignore-not-found || true
    log_success "ClusterRoleBinding 'vault-injector-clusterrolebinding' deleted"

    kubectl delete mutatingwebhookconfiguration vault-injector-cfg --ignore-not-found || true
    log_success "MutatingWebhookConfiguration 'vault-injector-cfg' deleted"
  else
    log_warn "Skipping vault cluster-scoped resource cleanup (managed-db-app still depends on them)"
  fi

  unset KUBECONFIG
else
  log_warn "Guest cluster kubeconfig not found at '${KUBECONFIG_FILE}' — skipping guest cluster cleanup"
fi

###############################################################################
# Phase 3: Supervisor Namespace Resource Cleanup
###############################################################################

log_step 3 "Switching to supervisor context and cleaning up supervisor resources"

# Ensure VCF CLI context exists
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
fi

# Delete KeyValueSecrets
echo "y" | vcf secret delete redis-creds 2>/dev/null || true
log_success "KeyValueSecret 'redis-creds' deleted"

echo "y" | vcf secret delete postgres-creds 2>/dev/null || true
log_success "KeyValueSecret 'postgres-creds' deleted"

# Delete ServiceAccount and token
kubectl delete sa internal-app --ignore-not-found 2>/dev/null || true
log_success "ServiceAccount 'internal-app' deleted"

kubectl delete secret internal-app-token --ignore-not-found 2>/dev/null || true
log_success "Secret 'internal-app-token' deleted"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Secrets Demo — Teardown Complete"
echo "============================================="
echo "  Namespace:  ${NAMESPACE} (deleted)"
echo "  Secrets:    redis-creds, postgres-creds (deleted)"
echo "  ServiceAccount: internal-app (deleted)"
echo "============================================="
echo ""

exit 0
