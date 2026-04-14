#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy GitOps — Self-Contained ArgoCD Consumption Model Teardown Script
#
# This script removes the self-contained ArgoCD Consumption Model stack
# installed by the Deploy GitOps deploy script, deleting resources in reverse
# dependency order:
#   Phase 1:  Kubeconfig Setup
#   Phase 1b: CI/CD Pipeline Cleanup
#   Phase 2:  Delete ArgoCD Application
#   Phase 3:  Delete GitLab Runner
#   Phase 4:  Delete GitLab
#   Phase 5:  Delete ArgoCD
#   Phase 6:  Restore CoreDNS
#   Phase 7:  Delete Harbor
#   Phase 8:  Delete Certificate Secrets
#   Phase 9:  Clean Up Certificate Files
#   Phase 10: Summary
#
# IMPORTANT: Helm releases are removed via `helm uninstall`. Finalizers are
# stripped from stuck resources before namespace deletion to prevent hanging
# namespaces (lesson learned from Deploy Metrics). All deletion commands use
# `--ignore-not-found` or `|| true` for idempotent re-runs.
#
# Uses the same variable block as the deploy script (subset).
# Run: bash examples/deploy-gitops/teardown-gitops.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
###############################################################################

# --- Cluster Identity ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"

# --- Domain ---
DOMAIN="${DOMAIN:-lab.local}"

# --- Certificate Directory ---
CERT_DIR="${CERT_DIR:-./certs}"

# --- Namespaces ---
CONTOUR_INGRESS_NAMESPACE="${CONTOUR_INGRESS_NAMESPACE:-tanzu-system-ingress}"
HARBOR_NAMESPACE="${HARBOR_NAMESPACE:-harbor}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab-system}"
GITLAB_RUNNER_NAMESPACE="${GITLAB_RUNNER_NAMESPACE:-gitlab-runners}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAMESPACE="${APP_NAMESPACE:-microservices-demo}"

# --- CI/CD Pipeline ---
GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-microservices-demo}"
HARBOR_CI_PROJECT="${HARBOR_CI_PROJECT:-microservices-ci}"

# --- Repository URLs ---
HELM_CHARTS_REPO_URL="${HELM_CHARTS_REPO_URL:-https://github.com/scafeman/vcf9-iac-onboarding.git}"

###############################################################################
# Derived Variables (computed from DOMAIN — do not edit)
###############################################################################

HARBOR_HOSTNAME="harbor.${DOMAIN}"
GITLAB_HOSTNAME="gitlab.${DOMAIN}"
ARGOCD_HOSTNAME="argocd.${DOMAIN}"

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
# strip_finalizers_in_namespace — Targeted finalizer removal
#
# Instead of enumerating every API resource type in the cluster (which can be
# 100+ types on VCF clusters with many CRDs and takes 10-20 minutes per
# namespace), we only strip finalizers from the resource types that commonly
# get stuck after a Helm uninstall. Additional resource types can be passed
# as arguments for component-specific CRs.
#
# Usage: strip_finalizers_in_namespace <namespace> [extra_resource_types...]
# Example: strip_finalizers_in_namespace gitlab-system gitlabs runners
###############################################################################

strip_finalizers_in_namespace() {
  local ns="$1"
  shift
  # Common resource types that can hold finalizers after Helm uninstall
  local resource_types=(
    pods
    services
    deployments
    statefulsets
    replicasets
    jobs
    persistentvolumeclaims
    secrets
    configmaps
    serviceaccounts
    ingresses
    "$@"
  )

  if ! kubectl get ns "${ns}" >/dev/null 2>&1; then
    return 0
  fi

  for resource in "${resource_types[@]}"; do
    # Skip empty entries (from unused extra args)
    [[ -z "${resource}" ]] && continue
    for item in $(kubectl get "${resource}" -n "${ns}" -o name 2>/dev/null); do
      kubectl patch "${item}" -n "${ns}" \
        --type merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
    done
  done
}

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables

###############################################################################
# Phase 1: Kubeconfig Setup
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
# Phase 1b: CI/CD Pipeline Cleanup
#
# Cleans up CI/CD pipeline resources created by Phases 16–18 of the deploy
# script. Must run BEFORE Phase 2 (Delete ArgoCD Application) because we need
# ArgoCD running to restore the Application source and remove repo credentials.
###############################################################################

log_step "1b" "Cleaning up CI/CD pipeline resources"

# --- 1b-a: Restore ArgoCD Application source to original GitHub repo ---

if kubectl get application microservices-demo -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  kubectl patch application microservices-demo -n "${ARGOCD_NAMESPACE}" --type merge -p '{
    "spec": {
      "source": {
        "repoURL": "'"${HELM_CHARTS_REPO_URL}"'",
        "path": "examples/deploy-gitops/microservices-overlay",
        "targetRevision": "HEAD"
      }
    }
  }' 2>/dev/null || true
  log_success "ArgoCD Application source restored to '${HELM_CHARTS_REPO_URL}'"
else
  log_warn "ArgoCD Application 'microservices-demo' not found, skipping source restore"
fi

# --- 1b-b: Remove ArgoCD repo credentials for GitLab ---

ARGOCD_POD=$(kubectl get pod -n "${ARGOCD_NAMESPACE}" \
  -l app.kubernetes.io/name=argocd-server \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -n "${ARGOCD_POD}" ]]; then
  # Retrieve ArgoCD admin password for CLI login
  ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n "${ARGOCD_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [[ -n "${ARGOCD_PASSWORD}" ]]; then
    kubectl exec -n "${ARGOCD_NAMESPACE}" "${ARGOCD_POD}" -- sh -c \
      "argocd login localhost:8080 --username admin --password '${ARGOCD_PASSWORD}' --plaintext --insecure" 2>/dev/null || true

    GITLAB_REPO_URL="https://${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}.git"
    kubectl exec -n "${ARGOCD_NAMESPACE}" "${ARGOCD_POD}" -- sh -c \
      "argocd repo rm '${GITLAB_REPO_URL}'" 2>/dev/null || true
    log_success "ArgoCD repo credentials for GitLab removed"
  else
    log_warn "Could not retrieve ArgoCD admin password, skipping repo credential removal"
  fi
else
  log_warn "ArgoCD server pod not found, skipping repo credential removal"
fi

# --- 1b-c: Delete GitLab project via API ---

# Retrieve GitLab root password from K8s secret
GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n "${GITLAB_NAMESPACE}" \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "${GITLAB_ROOT_PASSWORD}" ]]; then
  # Obtain an OAuth token for API access
  GITLAB_OAUTH_TOKEN=$(curl -sSk "https://${GITLAB_HOSTNAME}/oauth/token" \
    -d "grant_type=password&username=root&password=${GITLAB_ROOT_PASSWORD}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

  if [[ -n "${GITLAB_OAUTH_TOKEN}" ]]; then
    # Look up the project ID by name
    GITLAB_PROJECT_ID=$(curl -sSk \
      "https://${GITLAB_HOSTNAME}/api/v4/projects?search=${GITLAB_PROJECT_NAME}" \
      -H "PRIVATE-TOKEN: ${GITLAB_OAUTH_TOKEN}" 2>/dev/null \
      | python3 -c "
import sys, json
projects = json.load(sys.stdin)
for p in projects:
    if p['path'] == '${GITLAB_PROJECT_NAME}':
        print(p['id'])
        sys.exit(0)
print('')
" 2>/dev/null || true)

    if [[ -n "${GITLAB_PROJECT_ID}" ]]; then
      curl -sSk -X DELETE \
        "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}" \
        -H "PRIVATE-TOKEN: ${GITLAB_OAUTH_TOKEN}" 2>/dev/null || true
      log_success "GitLab project '${GITLAB_PROJECT_NAME}' (ID: ${GITLAB_PROJECT_ID}) deleted"
    else
      log_warn "GitLab project '${GITLAB_PROJECT_NAME}' not found, skipping deletion"
    fi
  else
    log_warn "Could not obtain GitLab OAuth token, skipping project deletion"
  fi
else
  log_warn "GitLab root password not available, skipping GitLab project deletion"
fi

# --- 1b-d: Delete Harbor CI project via API ---

# Retrieve Harbor admin password from the Harbor core secret
HARBOR_ADMIN_PASSWORD=$(kubectl get secret harbor-core -n "${HARBOR_NAMESPACE}" \
  -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)

if [[ -n "${HARBOR_ADMIN_PASSWORD}" ]]; then
  curl -sSk -X DELETE \
    -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    "https://${HARBOR_HOSTNAME}/api/v2.0/projects/${HARBOR_CI_PROJECT}" 2>/dev/null || true
  log_success "Harbor CI project '${HARBOR_CI_PROJECT}' deleted"
else
  log_warn "Harbor admin password not available, skipping Harbor CI project deletion"
fi

log_success "CI/CD pipeline cleanup complete"

###############################################################################
# Phase 2: Delete ArgoCD Application
###############################################################################

log_step 2 "Deleting ArgoCD Application"

# Delete the ArgoCD Application custom resource
kubectl delete application microservices-demo -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Wait for Microservices Demo pods to terminate
echo "  Waiting for pods in '${APP_NAMESPACE}' to terminate..."
TIMEOUT=120
ELAPSED=0
while [[ "${ELAPSED}" -lt "${TIMEOUT}" ]]; do
  POD_COUNT=$(kubectl get pods -n "${APP_NAMESPACE}" --no-headers 2>/dev/null | wc -l || echo "0")
  if [[ "${POD_COUNT}" -eq 0 ]]; then
    break
  fi
  echo "  ${POD_COUNT} pod(s) still terminating... (${ELAPSED}s/${TIMEOUT}s elapsed)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

# Delete the application namespace (--wait=false to avoid blocking on stuck finalizers)
kubectl delete ns "${APP_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

log_success "ArgoCD Application 'microservices-demo' deleted (namespace '${APP_NAMESPACE}' removed)"

###############################################################################
# Phase 3: Delete GitLab Runner
###############################################################################

log_step 3 "Deleting GitLab Runner"

# Uninstall the GitLab Runner Helm release (--no-hooks avoids running pre/post-delete hooks)
helm uninstall gitlab-runner -n "${GITLAB_RUNNER_NAMESPACE}" --no-hooks 2>/dev/null || true

# Strip finalizers from stuck resources (targeted types only — avoids slow
# enumeration of all 100+ API resource types on VCF clusters)
strip_finalizers_in_namespace "${GITLAB_RUNNER_NAMESPACE}"

# Delete the GitLab Runner namespace (--wait=false to avoid blocking on stuck finalizers)
kubectl delete ns "${GITLAB_RUNNER_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

log_success "GitLab Runner removed (namespace '${GITLAB_RUNNER_NAMESPACE}' deleted)"

###############################################################################
# Phase 4: Delete GitLab
###############################################################################

log_step 4 "Deleting GitLab"

# Uninstall the GitLab Helm release (--no-hooks avoids running pre/post-delete hooks)
helm uninstall gitlab -n "${GITLAB_NAMESPACE}" --no-hooks 2>/dev/null || true

# Delete GitLab custom resources first (the operator creates these)
kubectl delete gitlab --all -n "${GITLAB_NAMESPACE}" 2>/dev/null || true

# Strip finalizers from stuck resources (targeted types + GitLab CRs)
strip_finalizers_in_namespace "${GITLAB_NAMESPACE}" gitlabs runners

# Delete the GitLab namespace (--wait=false to avoid blocking on stuck finalizers)
kubectl delete ns "${GITLAB_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

log_success "GitLab removed (namespace '${GITLAB_NAMESPACE}' deleted)"

###############################################################################
# Phase 5: Delete ArgoCD
###############################################################################

log_step 5 "Deleting ArgoCD"

# Uninstall the ArgoCD Helm release (--no-hooks avoids running pre/post-delete hooks)
helm uninstall argocd -n "${ARGOCD_NAMESPACE}" --no-hooks 2>/dev/null || true

# Strip finalizers from stuck resources (targeted types + ArgoCD CRs)
strip_finalizers_in_namespace "${ARGOCD_NAMESPACE}" applications applicationsets appprojects

# Delete the ArgoCD namespace (--wait=false to avoid blocking on stuck finalizers)
kubectl delete ns "${ARGOCD_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

log_success "ArgoCD removed (namespace '${ARGOCD_NAMESPACE}' deleted)"

###############################################################################
# Phase 6: Restore CoreDNS
###############################################################################

log_step 6 "Restoring CoreDNS configuration"

# Get the current Corefile from the CoreDNS ConfigMap
CURRENT_COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null || true)

if [[ -n "${CURRENT_COREFILE}" ]]; then
  # Remove the hosts block we added (contains Harbor/GitLab/ArgoCD entries).
  # Use Python regex to remove the entire hosts { ... } block cleanly,
  # preventing stale empty blocks from accumulating across teardown/deploy
  # cycles (which would crash CoreDNS with "this plugin can only be used
  # once per Server Block").
  if echo "${CURRENT_COREFILE}" | grep -q "hosts"; then
    PATCHED_COREFILE=$(echo "${CURRENT_COREFILE}" | python3 -c '
import re, json, sys
corefile = sys.stdin.read()
cleaned = re.sub(r"\s*hosts\s*\{[^}]*\}\s*", "\n        ", corefile)
cleaned = re.sub(r"\n(\s*\n)+", "\n", cleaned)
print(json.dumps(cleaned))
')

    kubectl patch configmap coredns -n kube-system --type merge -p "{
      \"data\": {
        \"Corefile\": ${PATCHED_COREFILE}
      }
    }" 2>/dev/null || true

    # Restart CoreDNS pods to pick up the restored configuration
    kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true

    log_success "CoreDNS configuration restored (hosts block removed)"
  else
    log_success "CoreDNS does not contain custom hosts block, no changes needed"
  fi
else
  log_warn "Could not read CoreDNS ConfigMap, skipping CoreDNS restore"
fi

log_success "CoreDNS restore complete"

###############################################################################
# Phase 7: Delete Harbor
###############################################################################

log_step 7 "Deleting Harbor"

# Uninstall the Harbor Helm release (--no-hooks avoids running pre/post-delete hooks)
helm uninstall harbor -n "${HARBOR_NAMESPACE}" --no-hooks 2>/dev/null || true

# Strip finalizers from stuck resources (targeted types only)
strip_finalizers_in_namespace "${HARBOR_NAMESPACE}"

# Delete the Harbor namespace (--wait=false to avoid blocking on stuck finalizers)
kubectl delete ns "${HARBOR_NAMESPACE}" --ignore-not-found --wait=false 2>/dev/null || true

log_success "Harbor removed (namespace '${HARBOR_NAMESPACE}' deleted)"

###############################################################################
# Phase 8: Delete Certificate Secrets
###############################################################################

log_step 8 "Deleting certificate secrets"

# Delete Let's Encrypt Ingress resources (created by Phase 14b)
kubectl delete ingress harbor-letsencrypt-ingress -n "${HARBOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete ingress argocd-letsencrypt-ingress -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete ingress gitlab-letsencrypt-ingress -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true
kubectl delete ingress boutique-letsencrypt-ingress -n "${APP_NAMESPACE}" --ignore-not-found 2>/dev/null || true
log_success "Let's Encrypt Ingress resources deleted"

# Delete Harbor CA certificate secret from all relevant namespaces
for ns in "${GITLAB_NAMESPACE}" "${GITLAB_RUNNER_NAMESPACE}"; do
  kubectl delete secret harbor-ca-cert -n "${ns}" --ignore-not-found 2>/dev/null || true
done

# Delete GitLab wildcard TLS secret
kubectl delete secret gitlab-wildcard-tls -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true

# Delete sslip.io Certificate resources created by cert-manager
for ns in "${HARBOR_NAMESPACE}" "${ARGOCD_NAMESPACE}" "${GITLAB_NAMESPACE}"; do
  kubectl delete certificate --all -n "${ns}" --ignore-not-found 2>/dev/null || true
done

log_success "Certificate secrets and sslip.io resources deleted from all namespaces"

###############################################################################
# Phase 9: Clean Up Certificate Files
###############################################################################

log_step 9 "Cleaning up certificate files"

if [[ -d "${CERT_DIR}" ]]; then
  log_warn "Removing generated certificate files from '${CERT_DIR}'"
  rm -rf "${CERT_DIR}"
  log_success "Certificate directory '${CERT_DIR}' removed"
else
  log_success "Certificate directory '${CERT_DIR}' does not exist, nothing to clean up"
fi

log_success "Certificate file cleanup complete"

###############################################################################
# Phase 10: Summary Banner
###############################################################################

log_step 10 "Teardown summary"

echo ""
echo "============================================="
echo "  VCF 9 Deploy GitOps — Teardown Complete"
echo "============================================="
echo "  Cluster:              ${CLUSTER_NAME}"
echo "  Domain:               ${DOMAIN}"
echo "  Removed components:"
echo "    - CI/CD pipeline (GitLab project, Harbor CI project, ArgoCD repo credentials)"
echo "    - ArgoCD Application (microservices-demo)"
echo "    - Microservices Demo namespace (${APP_NAMESPACE})"
echo "    - GitLab Runner (ns: ${GITLAB_RUNNER_NAMESPACE})"
echo "    - GitLab (ns: ${GITLAB_NAMESPACE})"
echo "    - ArgoCD (ns: ${ARGOCD_NAMESPACE})"
echo "    - CoreDNS custom host entries"
echo "    - Harbor (ns: ${HARBOR_NAMESPACE})"
echo "    - Certificate secrets (harbor-ca-cert, gitlab-wildcard-tls)"
echo "    - Certificate files (${CERT_DIR})"
echo "============================================="
echo ""

log_success "Deploy GitOps teardown complete"

exit 0
