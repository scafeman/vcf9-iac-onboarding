#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Scenario 2 — VKS Metrics Observability Teardown Script
#
# This script removes the metrics observability stack installed by the
# Scenario 2 deploy script, deleting resources in reverse dependency order:
#   Phase 1: Kubeconfig Setup & Connectivity Check
#   Phase 2: Delete Grafana (Operator, instance, namespace)
#   Phase 3: Delete Packages (strip finalizers, delete PackageInstalls & Apps)
#   Phase 4: Delete Package Repository
#   Phase 5: Delete Package Namespace
#   Phase 6: Clean Up Cluster-Scoped Resources
#
# IMPORTANT: Packages are NOT deleted via `vcf package installed delete`
# because kapp-controller's reconcile-delete cascades into deleting the
# shared namespace, which destroys service accounts needed by other packages.
# Instead, we strip finalizers from all PackageInstall and App resources so
# kapp-controller releases them immediately, then clean up ourselves.
#
# Uses the same variable block as the deploy script (subset).
# Run: bash examples/scenario2/scenario2-vks-metrics-teardown.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
###############################################################################

# --- Cluster Identity ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"

# --- Package Repository ---
PACKAGE_NAMESPACE="${PACKAGE_NAMESPACE:-tkg-packages}"
PACKAGE_REPO_NAME="${PACKAGE_REPO_NAME:-tkg-packages}"

# --- Grafana ---
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"

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
# Phase 3: Delete Packages
#
# Delete all VKS standard packages in reverse dependency order. Each package's
# PackageInstall and App resources have their finalizers stripped before
# deletion so kapp-controller does NOT trigger a reconcile-delete. This
# prevents the cascading namespace deletion that breaks other packages.
###############################################################################

log_step 3 "Deleting packages (reverse dependency order)"

delete_package prometheus
delete_package contour
delete_package cert-manager
delete_package telegraf

log_success "All packages deleted"

###############################################################################
# Phase 4: Delete Package Repository
###############################################################################

log_step 4 "Deleting package repository"

if kubectl get packagerepository -n "${PACKAGE_NAMESPACE}" --no-headers 2>/dev/null | grep -qi "${PACKAGE_REPO_NAME}"; then
  # Strip finalizers first, then delete
  kubectl patch packagerepository "${PACKAGE_REPO_NAME}" -n "${PACKAGE_NAMESPACE}" \
    --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  kubectl delete packagerepository "${PACKAGE_REPO_NAME}" -n "${PACKAGE_NAMESPACE}" --ignore-not-found 2>/dev/null || true

  log_success "Package repository '${PACKAGE_REPO_NAME}' deleted"
else
  log_success "Package repository '${PACKAGE_REPO_NAME}' not found, skipping"
fi

###############################################################################
# Phase 5: Delete Package Namespace
#
# By this point all PackageInstall, App, and PackageRepository resources
# should already be gone (finalizers stripped in earlier phases). If any
# stragglers remain, strip their finalizers before deleting the namespace.
###############################################################################

log_step 5 "Deleting package namespace"

if kubectl get ns "${PACKAGE_NAMESPACE}" >/dev/null 2>&1; then
  # Safety net: strip finalizers from any remaining carvel resources
  for pkg in $(kubectl get packageinstall -n "${PACKAGE_NAMESPACE}" -o name 2>/dev/null); do
    kubectl patch "${pkg}" -n "${PACKAGE_NAMESPACE}" --type merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
  for app in $(kubectl get app -n "${PACKAGE_NAMESPACE}" -o name 2>/dev/null); do
    kubectl patch "${app}" -n "${PACKAGE_NAMESPACE}" --type merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done
  for repo in $(kubectl get packagerepository -n "${PACKAGE_NAMESPACE}" -o name 2>/dev/null); do
    kubectl patch "${repo}" -n "${PACKAGE_NAMESPACE}" --type merge \
      -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
  done

  # Attempt namespace deletion with a timeout; if it hangs, force-remove
  # the namespace finalizer so it can terminate.
  if ! kubectl delete ns "${PACKAGE_NAMESPACE}" --ignore-not-found --timeout=60s 2>/dev/null; then
    log_warn "Namespace deletion timed out, force-removing namespace finalizer"
    kubectl get ns "${PACKAGE_NAMESPACE}" -o json 2>/dev/null \
      | jq '.spec.finalizers = []' \
      | kubectl replace --raw "/api/v1/namespaces/${PACKAGE_NAMESPACE}/finalize" -f - 2>/dev/null || true
    sleep 5
  fi

  log_success "Namespace '${PACKAGE_NAMESPACE}' deleted"
else
  log_success "Namespace '${PACKAGE_NAMESPACE}' does not exist, skipping"
fi

###############################################################################
# Phase 6: Clean Up Cluster-Scoped Resources
#
# kapp-controller tracks ownership of cluster-scoped resources (ClusterRoles,
# ClusterRoleBindings, CRDs, webhooks, Roles in kube-system) using labels.
# Since we bypassed kapp's reconcile-delete, these resources are still present
# and must be removed manually so a subsequent deploy starts clean.
###############################################################################

log_step 6 "Cleaning up cluster-scoped resources"

# --- Telegraf ---
for cr in telegraf telegraf-kubelet-metric-access telegraf-stats-viewer "telegraf:user" \
          telegraf-tkg-packages-cluster-role; do
  kubectl delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
done
for crb in telegraf telegraf-tkg-packages-cluster-rolebinding; do
  kubectl delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
done

# --- cert-manager ---
for cr in cert-manager-cainjector cert-manager-cluster-view \
          cert-manager-controller-approve:cert-manager-io \
          cert-manager-controller-certificates \
          cert-manager-controller-certificatesigningrequests \
          cert-manager-controller-challenges \
          cert-manager-controller-clusterissuers \
          cert-manager-controller-ingress-shim \
          cert-manager-controller-issuers \
          cert-manager-controller-orders \
          cert-manager-edit cert-manager-view \
          cert-manager-webhook:subjectaccessreviews \
          cert-manager-tkg-packages-cluster-role; do
  kubectl delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
done
for crb in cert-manager-cainjector \
           cert-manager-controller-approve:cert-manager-io \
           cert-manager-controller-certificates \
           cert-manager-controller-certificatesigningrequests \
           cert-manager-controller-challenges \
           cert-manager-controller-clusterissuers \
           cert-manager-controller-ingress-shim \
           cert-manager-controller-issuers \
           cert-manager-controller-orders \
           cert-manager-webhook:subjectaccessreviews \
           cert-manager-tkg-packages-cluster-rolebinding; do
  kubectl delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
done
# cert-manager webhooks
kubectl delete validatingwebhookconfiguration cert-manager-webhook --ignore-not-found 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration cert-manager-webhook --ignore-not-found 2>/dev/null || true
# cert-manager CRDs
for crd in certificaterequests.cert-manager.io certificates.cert-manager.io \
           challenges.acme.cert-manager.io clusterissuers.cert-manager.io \
           issuers.cert-manager.io orders.acme.cert-manager.io; do
  kubectl delete crd "$crd" --ignore-not-found 2>/dev/null || true
done
# cert-manager roles in kube-system
kubectl delete role cert-manager-cainjector:leaderelection -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete role cert-manager:leaderelection -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete rolebinding cert-manager-cainjector:leaderelection -n kube-system --ignore-not-found 2>/dev/null || true
kubectl delete rolebinding cert-manager:leaderelection -n kube-system --ignore-not-found 2>/dev/null || true
# cert-manager namespace (created by the package, separate from tkg-packages)
kubectl delete ns cert-manager --ignore-not-found 2>/dev/null || true

# --- Contour ---
for cr in contour envoy contour-tkg-packages-cluster-role; do
  kubectl delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
done
for crb in contour envoy contour-tkg-packages-cluster-rolebinding; do
  kubectl delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
done
# Contour CRDs
for crd in contourconfigurations.projectcontour.io contourdeployments.projectcontour.io \
           extensionservices.projectcontour.io httpproxies.projectcontour.io \
           tlscertificatedelegations.projectcontour.io; do
  kubectl delete crd "$crd" --ignore-not-found 2>/dev/null || true
done
# Contour namespace (tanzu-system-ingress, created by the package)
kubectl delete ns tanzu-system-ingress --ignore-not-found 2>/dev/null || true

# --- Prometheus ---
for cr in alertmanager prometheus-server prometheus-kube-state-metrics \
          prometheus-node-exporter prometheus-pushgateway \
          prometheus-tkg-packages-cluster-role; do
  kubectl delete clusterrole "$cr" --ignore-not-found 2>/dev/null || true
done
for crb in alertmanager prometheus-server prometheus-kube-state-metrics \
           prometheus-node-exporter prometheus-pushgateway \
           prometheus-tkg-packages-cluster-rolebinding; do
  kubectl delete clusterrolebinding "$crb" --ignore-not-found 2>/dev/null || true
done

log_success "Cluster-scoped resources cleaned up"

###############################################################################
# Teardown Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Scenario 2 — Teardown Complete"
echo "============================================="
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Namespace:  ${PACKAGE_NAMESPACE} (deleted)"
echo "  Packages:   All observability packages removed"
echo "  Cleanup:    Cluster-scoped resources removed"
echo "============================================="
echo ""

exit 0
