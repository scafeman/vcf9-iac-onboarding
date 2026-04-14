#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Metrics — VKS Metrics Observability Teardown Script
#
# This script removes the metrics observability stack installed by the
# Deploy Metrics deploy script, deleting ONLY metrics-owned resources:
#   Phase 1: Kubeconfig Setup & Connectivity Check
#   Phase 2: Delete Grafana (Operator, instance, namespace)
#   Phase 2b: Remove CoreDNS hosts entry
#   Phase 3: Delete metrics-owned packages (prometheus and telegraf ONLY)
#
# IMPORTANT: This script does NOT delete shared infrastructure:
#   - tkg-packages namespace, package repository
#   - cert-manager package, Contour package
#   - envoy-lb LoadBalancer service
#   - ClusterIssuers, cert-manager/Contour CRDs, ClusterRoles, etc.
# Shared infrastructure is ONLY deleted by teardown-cluster.sh.
#
# Packages are NOT deleted via `vcf package installed delete` because
# kapp-controller's reconcile-delete cascades into deleting the shared
# namespace. Instead, we strip finalizers and delete directly.
#
# Uses the same variable block as the deploy script (subset).
# Run: bash examples/deploy-metrics/teardown-metrics.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
###############################################################################

# --- Cluster Identity ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"

# --- Domain ---
DOMAIN="${DOMAIN:-lab.local}"

# --- Package Repository ---
PACKAGE_NAMESPACE="${PACKAGE_NAMESPACE:-tkg-packages}"
PACKAGE_REPO_NAME="${PACKAGE_REPO_NAME:-tkg-packages}"

# --- Grafana ---
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"

###############################################################################
# Derived Variables
###############################################################################

GRAFANA_HOSTNAME="grafana.${DOMAIN}"

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

###############################################################################
# Package deletion helper
#
# Strips finalizers from the PackageInstall and its companion App resource,
# then deletes both. This avoids triggering kapp-controller's reconcile-delete
# which would cascade into deleting the shared namespace and its service
# accounts, breaking deletion of other packages.
###############################################################################

delete_package() {
  local pkg_name="$1"

  # Broad detection: list all PackageInstalls and grep for the name.
  if kubectl get packageinstall -n "${PACKAGE_NAMESPACE}" --no-headers 2>/dev/null | grep -qi "${pkg_name}"; then
    # Strip finalizers FIRST so kapp-controller releases the resources
    # without attempting a reconcile-delete (which would cascade).
    kubectl patch packageinstall "${pkg_name}" -n "${PACKAGE_NAMESPACE}" \
      --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    kubectl patch app "${pkg_name}" -n "${PACKAGE_NAMESPACE}" \
      --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true

    # Now delete the resources — kapp-controller won't reconcile because
    # finalizers are already gone.
    kubectl delete packageinstall "${pkg_name}" -n "${PACKAGE_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete app "${pkg_name}" -n "${PACKAGE_NAMESPACE}" --ignore-not-found 2>/dev/null || true

    log_success "${pkg_name} package deleted"
  else
    log_success "${pkg_name} package not found, skipping"
  fi
}

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

###############################################################################
# Phase 1: Kubeconfig Setup & Connectivity Check
###############################################################################

log_step 1 "Setting up kubeconfig"

export KUBECONFIG="${KUBECONFIG_FILE}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  log_warn "Kubeconfig file not found at '${KUBECONFIG_FILE}'. Some cleanup steps may be skipped."
fi

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_warn "Unable to reach cluster '${CLUSTER_NAME}' — will attempt cleanup anyway"
fi

log_success "Kubeconfig set to '${KUBECONFIG_FILE}'"

###############################################################################
# Phase 2: Delete Grafana
###############################################################################

log_step 2 "Deleting Grafana"

# Remove Grafana Ingress and TLS secret
kubectl delete ingress grafana-ingress -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true
kubectl delete certificate grafana-ingress-tls -n "${GRAFANA_NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete secret grafana-tls -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true

# Remove Grafana CRs first (dashboards, datasource, instance)
kubectl delete grafanadashboard --all -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true
kubectl delete grafanadatasource --all -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true
kubectl delete grafana --all -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true

# Uninstall the Grafana Operator Helm release
helm uninstall grafana-operator --namespace "${GRAFANA_NAMESPACE}" 2>/dev/null || true

# Clean up Grafana CRDs (Helm doesn't remove CRDs on uninstall)
kubectl get crd -o name 2>/dev/null | grep grafana | xargs -r kubectl delete --ignore-not-found 2>/dev/null || true

# Delete the Grafana namespace
kubectl delete ns "${GRAFANA_NAMESPACE}" --ignore-not-found || true

log_success "Grafana removed (namespace '${GRAFANA_NAMESPACE}' deleted)"

###############################################################################
# Phase 2b: Remove Grafana CoreDNS Entry
#
# NOTE: envoy-lb and other shared infrastructure (cert-manager, Contour,
# package repository, tkg-packages namespace) are NOT deleted here.
# Shared infrastructure is ONLY deleted by teardown-cluster.sh.
###############################################################################

log_step "2b" "Removing Grafana CoreDNS entry"

CURRENT_COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

if echo "${CURRENT_COREFILE}" | grep -q "hosts"; then
  # Remove the entire hosts block (including the wrapper braces) so that
  # repeated teardown/deploy cycles don't leave empty hosts { fallthrough }
  # blocks behind. Previous versions only deleted the hostname line, which
  # caused CoreDNS to crash with "this plugin can only be used once per
  # Server Block" after multiple cycles.
  PATCHED_COREFILE=$(echo "${CURRENT_COREFILE}" | python3 -c '
import re, json, sys
corefile = sys.stdin.read()
cleaned = re.sub(r"\s*hosts\s*\{[^}]*\}\s*", "\n        ", corefile)
# Collapse any resulting blank-line runs
cleaned = re.sub(r"\n(\s*\n)+", "\n", cleaned)
print(json.dumps(cleaned))
')

  kubectl patch configmap coredns -n kube-system --type merge -p "{
    \"data\": {
      \"Corefile\": ${PATCHED_COREFILE}
    }
  }" 2>/dev/null || true

  kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
  log_success "CoreDNS hosts block removed"
else
  log_success "CoreDNS hosts block not found, skipping"
fi

###############################################################################
# Phase 3: Delete Metrics-Owned Packages (prometheus and telegraf ONLY)
#
# Only prometheus and telegraf are owned by the metrics stack. Shared packages
# (cert-manager, Contour) are NOT deleted here — they are managed by
# teardown-cluster.sh. Finalizers are stripped before deletion so
# kapp-controller does NOT trigger a reconcile-delete cascade.
###############################################################################

log_step 3 "Deleting metrics-owned packages (prometheus and telegraf)"

delete_package prometheus
delete_package telegraf

log_success "Metrics-owned packages deleted"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Metrics — Teardown Complete"
echo "============================================="
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Grafana:    ${GRAFANA_NAMESPACE} (deleted)"
echo "  Packages:   prometheus, telegraf (deleted)"
echo "  NOTE:       Shared infrastructure preserved"
echo "              (tkg-packages, cert-manager, Contour, envoy-lb)"
echo "============================================="
echo ""

exit 0
