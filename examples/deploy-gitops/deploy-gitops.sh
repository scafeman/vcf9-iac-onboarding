#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy GitOps — Self-Contained ArgoCD Consumption Model Deploy Script
#
# This script installs the full ArgoCD Consumption Model stack on an existing
# VKS cluster provisioned by Deploy Cluster. Infrastructure services (cert-manager,
# Contour) are installed as VKS standard packages (shared with Deploy Metrics).
# Application services (Harbor, ArgoCD, GitLab) are installed via Helm.
#
#   Phase 1:  Kubeconfig Setup & Connectivity Check
#   Phase 2:  Self-Signed Certificate Generation
#   Phase 3:  VKS Package Prerequisites (cert-manager, Contour, envoy-lb)
#   Phase 4:  Harbor Installation (Helm)
#   Phase 5:  CoreDNS Configuration (static DNS entries, pod restart)
#   Phase 6:  ArgoCD Installation (Helm)
#   Phase 7:  ArgoCD CLI Installation (auto-download)
#   Phase 8:  Certificate Distribution (Harbor CA, GitLab wildcard TLS)
#   Phase 9:  GitLab Installation (Helm)
#   Phase 10: GitLab Image Patching / Harbor Proxy Configuration
#   Phase 11: GitLab Runner Installation (Helm)
#   Phase 11b: Disable GitLab Public Sign-Up (API)
#   Phase 12: ArgoCD Cluster Registration
#   Phase 13: ArgoCD Application Bootstrap
#   Phase 14: Microservices Demo Verification
#   Phase 14b: Let's Encrypt TLS Ingress (external-facing trusted certs)
#   Phase 16: Harbor CI Project & GitLab Project Creation
#   Phase 17: ArgoCD Re-Point to GitLab
#   Phase 18: Pipeline Verification & Demo Instructions
#   Phase 15: Summary
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running with LB support)
#   - Valid admin kubeconfig file for the target cluster
#   - Helm v4 installed
#   - kubectl installed
#   - openssl installed
#   - vcf CLI installed (for VKS package installation)
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-gitops/deploy-gitops.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
#
# Fill in the required variables below. Variables with defaults can be
# overridden by setting them in your environment before running the script.
###############################################################################

# --- Cluster Identity ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-./kubeconfig-${CLUSTER_NAME}.yaml}"

# --- Domain ---
DOMAIN="${DOMAIN:-lab.local}"

# --- Infrastructure Versions ---
HARBOR_VERSION="${HARBOR_VERSION:-1.18.3}"
ARGOCD_VERSION="${ARGOCD_VERSION:-9.4.17}"

# --- Harbor Credentials ---
# If HARBOR_ADMIN_PASSWORD is not set, a random 24-character password is
# generated at runtime (similar to how ArgoCD and GitLab generate theirs
# via K8s Secrets). Override with a specific value if needed.
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-$(openssl rand -base64 18)}"
HARBOR_SECRET_KEY="${HARBOR_SECRET_KEY:-$(openssl rand -hex 16)}"
HARBOR_DB_PASSWORD="${HARBOR_DB_PASSWORD:-changeit}"

# --- Certificate Directory ---
CERT_DIR="${CERT_DIR:-./certs}"

# --- GitLab Versions ---
GITLAB_OPERATOR_VERSION="${GITLAB_OPERATOR_VERSION:-9.10.3}"
GITLAB_RUNNER_VERSION="${GITLAB_RUNNER_VERSION:-0.87.1}"
# GITLAB_RUNNER_TOKEN is auto-retrieved from the GitLab instance after Phase 9.
# Set it here only if you already have a token from a previous deployment.
GITLAB_RUNNER_TOKEN="${GITLAB_RUNNER_TOKEN:-}"

# --- Namespaces ---
CONTOUR_INGRESS_NAMESPACE="${CONTOUR_INGRESS_NAMESPACE:-tanzu-system-ingress}"
HARBOR_NAMESPACE="${HARBOR_NAMESPACE:-harbor}"
GITLAB_NAMESPACE="${GITLAB_NAMESPACE:-gitlab-system}"
GITLAB_RUNNER_NAMESPACE="${GITLAB_RUNNER_NAMESPACE:-gitlab-runners}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAMESPACE="${APP_NAMESPACE:-microservices-demo}"

# --- Repository URLs ---
# Git repository containing the microservices demo Helm chart for ArgoCD.
# Defaults to the Google Cloud Platform microservices-demo public repo.
HELM_CHARTS_REPO_URL="${HELM_CHARTS_REPO_URL:-https://github.com/scafeman/vcf9-iac-onboarding.git}"
ARGOCD_TARGET_REVISION="${ARGOCD_TARGET_REVISION:-HEAD}"

# --- Package Repository (shared with Deploy Metrics) ---
PACKAGE_NAMESPACE="${PACKAGE_NAMESPACE:-tkg-packages}"
PACKAGE_REPO_NAME="${PACKAGE_REPO_NAME:-tkg-packages}"
PACKAGE_REPO_URL="${PACKAGE_REPO_URL:-projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211}"

# --- Configuration File Paths ---
HARBOR_VALUES_FILE="${HARBOR_VALUES_FILE:-examples/deploy-gitops/harbor-values.yaml}"
ARGOCD_VALUES_FILE="${ARGOCD_VALUES_FILE:-examples/deploy-gitops/argocd-values.yaml}"
GITLAB_OPERATOR_VALUES_FILE="${GITLAB_OPERATOR_VALUES_FILE:-examples/deploy-gitops/gitlab-operator-values.yaml}"
GITLAB_RUNNER_VALUES_FILE="${GITLAB_RUNNER_VALUES_FILE:-examples/deploy-gitops/gitlab-runner-values.yaml}"
ARGOCD_APP_MANIFEST="${ARGOCD_APP_MANIFEST:-examples/deploy-gitops/argocd-microservices-demo.yaml}"

# --- Timeouts and Polling ---
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-900}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# --- sslip.io & Let's Encrypt ---
USE_SSLIP_DNS="${USE_SSLIP_DNS:-true}"
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-letsencrypt-prod}"
CERT_WAIT_TIMEOUT="${CERT_WAIT_TIMEOUT:-300}"

# --- CI/CD Pipeline Configuration ---
GITLAB_PROJECT_NAME="${GITLAB_PROJECT_NAME:-microservices-demo}"
HARBOR_CI_PROJECT="${HARBOR_CI_PROJECT:-microservices-ci}"
DEMO_BANNER_TEXT="${DEMO_BANNER_TEXT:-}"

###############################################################################
# Derived Variables (computed from DOMAIN — do not edit)
###############################################################################

HARBOR_HOSTNAME="harbor.${DOMAIN}"
GITLAB_HOSTNAME="gitlab.${DOMAIN}"
ARGOCD_HOSTNAME="argocd.${DOMAIN}"

###############################################################################
# Shared Helper Library
###############################################################################

source "$(dirname "$0")/../shared/sslip-helpers.sh"

###############################################################################
# Helper Functions
###############################################################################

log_step() {
  local step_number="$1"
  local message="$2"
  echo "[Step ${step_number}] ${message}..."
}

log_success() {
  local message="$1"
  echo "✓ ${message}"
}

log_error() {
  local message="$1"
  echo "✗ ERROR: ${message}" >&2
}

log_warn() {
  local message="$1"
  echo "⚠ WARNING: ${message}"
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

check_prerequisites() {
  local missing=0

  if ! command -v kubectl &>/dev/null; then
    log_error "kubectl is not installed or not in PATH"
    missing=1
  fi

  if ! command -v helm &>/dev/null; then
    log_error "helm is not installed or not in PATH"
    missing=1
  fi

  if ! command -v vcf &>/dev/null; then
    log_error "vcf CLI is not installed or not in PATH"
    missing=1
  fi

  if ! command -v openssl &>/dev/null; then
    log_error "openssl is not installed or not in PATH"
    missing=1
  fi

  if [[ "${missing}" -eq 1 ]]; then
    log_error "One or more required tools are missing. Install them and retry."
    exit 1
  fi
}

wait_for_condition() {
  local description="$1"
  local timeout="$2"
  local interval="$3"
  local check_command="$4"
  local elapsed=0

  while [[ "${elapsed}" -lt "${timeout}" ]]; do
    if eval "${check_command}" >/dev/null 2>&1; then
      return 0
    fi
    echo "  Waiting for ${description}... (${elapsed}s/${timeout}s elapsed)"
    sleep "${interval}"
    elapsed=$((elapsed + interval))
  done

  echo "  Timeout waiting for ${description} after ${elapsed}s"
  return 1
}

# Wait for the API server to become reachable. CoreDNS restarts and other
# cluster operations can cause transient "connection refused" errors on the
# VKS control plane. This helper blocks until kubectl can reach the API
# server, preventing subsequent vcf/kubectl commands from failing.
wait_for_api_server() {
  if ! wait_for_condition "API server to be reachable" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "kubectl get ns"; then
    log_error "API server did not become reachable within ${PACKAGE_TIMEOUT}s"
    exit 2
  fi
}

# Install a VKS package with automatic retry. The vcf CLI can fail with
# transient "connection refused" errors after CoreDNS restarts or during
# brief API server unavailability windows. This wrapper retries the install
# command up to 3 times with a pause between attempts.
install_package_with_retry() {
  local max_retries=3
  local attempt=1
  while [[ "${attempt}" -le "${max_retries}" ]]; do
    if "$@"; then
      return 0
    fi
    if [[ "${attempt}" -lt "${max_retries}" ]]; then
      log_warn "Package install failed (attempt ${attempt}/${max_retries}), waiting for API server before retry..."
      wait_for_api_server
      attempt=$((attempt + 1))
    else
      return 1
    fi
  done
}

###############################################################################
# Temporary Values File Preparation
#
# The Helm values files and ArgoCD manifest contain placeholder variables
# (HARBOR_HOSTNAME, GITLAB_HOSTNAME, ARGOCD_HOSTNAME, GITLAB_RUNNER_TOKEN,
# HELM_CHARTS_REPO_URL, APP_NAMESPACE, GITLAB_DOMAIN, HARBOR_ADMIN_PASSWORD,
# HARBOR_SECRET_KEY, HARBOR_DB_PASSWORD). This function creates temporary
# copies with all placeholders replaced by actual runtime values.
###############################################################################

TEMP_DIR=""

prepare_values_files() {
  TEMP_DIR=$(mktemp -d)
  log_success "Temporary values directory created at '${TEMP_DIR}'"

  # Extract the base domain for GitLab (DOMAIN without leading dot)
  local gitlab_domain="${DOMAIN}"

  # List of placeholder → value mappings
  # Each values file may use a subset of these
  local -a sed_args=(
    -e "s|HARBOR_HOSTNAME|${HARBOR_HOSTNAME}|g"
    -e "s|GITLAB_HOSTNAME|${GITLAB_HOSTNAME}|g"
    -e "s|ARGOCD_HOSTNAME|${ARGOCD_HOSTNAME}|g"
    -e "s|GITLAB_DOMAIN|${gitlab_domain}|g"
    -e "s|HELM_CHARTS_REPO_URL|${HELM_CHARTS_REPO_URL}|g"
    -e "s|ARGOCD_TARGET_REVISION|${ARGOCD_TARGET_REVISION}|g"
    -e "s|APP_NAMESPACE|${APP_NAMESPACE}|g"
    -e "s|Harbor12345|${HARBOR_ADMIN_PASSWORD}|g"
    -e "s|not-a-secure-key|${HARBOR_SECRET_KEY}|g"
    -e "s|changeit|${HARBOR_DB_PASSWORD}|g"
  )

  # Harbor values — substitute hardcoded lab.local hostnames and credentials
  sed "${sed_args[@]}" \
    -e "s|harbor\.lab\.local|${HARBOR_HOSTNAME}|g" \
    "${HARBOR_VALUES_FILE}" > "${TEMP_DIR}/harbor-values.yaml"

  # ArgoCD values — substitute hardcoded argocd.lab.local hostname
  sed "${sed_args[@]}" \
    -e "s|argocd\.lab\.local|${ARGOCD_HOSTNAME}|g" \
    "${ARGOCD_VALUES_FILE}" > "${TEMP_DIR}/argocd-values.yaml"

  # GitLab Operator values — substitute placeholder hostnames
  sed "${sed_args[@]}" \
    "${GITLAB_OPERATOR_VALUES_FILE}" > "${TEMP_DIR}/gitlab-operator-values.yaml"

  # ArgoCD Application manifest — substitute repo URL and namespace
  sed "${sed_args[@]}" \
    "${ARGOCD_APP_MANIFEST}" > "${TEMP_DIR}/argocd-microservices-demo.yaml"

  log_success "Values files prepared with runtime variable substitution"
}

# Prepare the GitLab Runner values file separately (called after token retrieval)
prepare_runner_values() {
  local -a sed_args=(
    -e "s|HARBOR_HOSTNAME|${HARBOR_HOSTNAME}|g"
    -e "s|GITLAB_HOSTNAME|${GITLAB_HOSTNAME}|g"
    -e "s|GITLAB_RUNNER_TOKEN|${GITLAB_RUNNER_TOKEN}|g"
  )

  sed "${sed_args[@]}" \
    "${GITLAB_RUNNER_VALUES_FILE}" > "${TEMP_DIR}/gitlab-runner-values.yaml"

  log_success "GitLab Runner values file prepared with runner token"
}

cleanup_temp() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf "${TEMP_DIR}"
  fi
}

trap cleanup_temp EXIT

###############################################################################
# Pre-Flight Validation
###############################################################################

validate_variables
check_prerequisites

###############################################################################
# Phase 1: Kubeconfig Setup & Connectivity Check
###############################################################################

log_step 1 "Setting up kubeconfig"

export KUBECONFIG="${KUBECONFIG_FILE}"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  log_error "Kubeconfig file not found at '${KUBECONFIG_FILE}'. Ensure Deploy Cluster has completed and the kubeconfig file exists."
  exit 2
fi

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_error "Unable to reach cluster '${CLUSTER_NAME}' using kubeconfig at '${KUBECONFIG_FILE}'. Verify the cluster is running and the kubeconfig is valid."
  exit 2
fi

log_success "Kubeconfig set and cluster '${CLUSTER_NAME}' is reachable"

# Prepare temporary values files with placeholder substitution
prepare_values_files

###############################################################################
# Phase 2: Self-Signed Certificate Generation
# When USE_SSLIP_DNS=true, certs are generated AFTER envoy-lb IP is known
# (moved to Phase 3b below). When false, generate now with lab.local domain.
###############################################################################

if [[ "${USE_SSLIP_DNS}" != "true" ]]; then

log_step 2 "Generating self-signed certificates for *.${DOMAIN}"

if [[ -f "${CERT_DIR}/ca.crt" ]]; then
  log_success "CA certificate already exists at '${CERT_DIR}/ca.crt', skipping certificate generation"
else
  mkdir -p "${CERT_DIR}"

  if ! openssl req -x509 -new -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" \
    -days 3650 -subj "/CN=Self-Signed CA"; then
    log_error "Failed to generate self-signed CA certificate"
    exit 3
  fi
  log_success "Self-signed CA certificate generated"

  if ! openssl req -new -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/wildcard.key" -out "${CERT_DIR}/wildcard.csr" \
    -config examples/deploy-gitops/wildcard.cnf; then
    log_error "Failed to generate wildcard certificate CSR"
    exit 3
  fi
  log_success "Wildcard certificate CSR generated"

  if ! openssl x509 -req -in "${CERT_DIR}/wildcard.csr" \
    -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial -out "${CERT_DIR}/wildcard.crt" \
    -days 3650 -extensions v3_req -extfile examples/deploy-gitops/wildcard.cnf; then
    log_error "Failed to sign wildcard certificate"
    exit 3
  fi
  log_success "Wildcard certificate signed by CA"

  cat "${CERT_DIR}/wildcard.crt" "${CERT_DIR}/ca.crt" > "${CERT_DIR}/fullchain.crt"
  log_success "Fullchain certificate created"
fi

log_success "Certificates ready in '${CERT_DIR}'"

else
  log_step 2 "Deferring certificate generation until envoy-lb IP is known (USE_SSLIP_DNS=true)"
fi

###############################################################################
# Phase 3: VKS Package Prerequisites (cert-manager, Contour, envoy-lb)
#
# Contour and cert-manager are installed as VKS standard packages (the same
# packages used by Deploy Metrics). If Deploy Metrics has already been deployed,
# these packages will already exist and this phase skips installation.
# A separate envoy-lb LoadBalancer service is created to provide external
# access (the VKS Contour package creates Envoy as NodePort by default).
###############################################################################

log_step 3 "Installing VKS package prerequisites (cert-manager, Contour)"

# --- Package Namespace ---
if kubectl get ns "${PACKAGE_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${PACKAGE_NAMESPACE}' already exists, skipping creation"
else
  if ! kubectl create ns "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to create namespace '${PACKAGE_NAMESPACE}'"
    exit 4
  fi
  log_success "Namespace '${PACKAGE_NAMESPACE}' created"
fi

kubectl label ns "${PACKAGE_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null 2>&1 || true

# --- Package Repository ---
if vcf package repository list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "${PACKAGE_REPO_NAME}"; then
  log_success "Package repository '${PACKAGE_REPO_NAME}' already exists, skipping registration"
else
  if ! vcf package repository add "${PACKAGE_REPO_NAME}" \
    --url "${PACKAGE_REPO_URL}" \
    --namespace "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to register package repository '${PACKAGE_REPO_NAME}'"
    exit 4
  fi

  if ! wait_for_condition "package repository '${PACKAGE_REPO_NAME}' to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package repository list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep '${PACKAGE_REPO_NAME}' | grep -qi 'reconcile'"; then
    log_error "Package repository '${PACKAGE_REPO_NAME}' did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 4
  fi

  log_success "Package repository '${PACKAGE_REPO_NAME}' registered and reconciled"
fi

# --- cert-manager (Contour prerequisite) ---
if vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -qi 'cert-manager'; then
  log_success "cert-manager package already installed, skipping"
else
  if ! install_package_with_retry vcf package install cert-manager \
    -p cert-manager.kubernetes.vmware.com \
    -n "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to install cert-manager package"
    exit 4
  fi

  if ! wait_for_condition "cert-manager package to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'cert-manager' | grep -qi 'reconcile'"; then
    log_error "cert-manager package did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 4
  fi

  log_success "cert-manager installed and reconciled"
fi

# --- Contour (VKS package) ---
if vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -qi 'contour'; then
  log_success "Contour package already installed, skipping"
else
  if ! install_package_with_retry vcf package install contour \
    -p contour.kubernetes.vmware.com \
    -n "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to install Contour package"
    exit 4
  fi

  if ! wait_for_condition "Contour package to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'contour' | grep -qi 'reconcile'"; then
    log_error "Contour package did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 4
  fi

  log_success "Contour installed and reconciled"
fi

# --- envoy-lb LoadBalancer service ---
# The VKS Contour package creates Envoy as a DaemonSet with NodePort service
# in tanzu-system-ingress. kapp-controller reverts direct patches. Create a
# separate LoadBalancer service targeting the same Envoy pods for external access.
if kubectl get svc envoy-lb -n "${CONTOUR_INGRESS_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Envoy LoadBalancer service 'envoy-lb' already exists"
else
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: envoy-lb
  namespace: ${CONTOUR_INGRESS_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: envoy
  ports:
    - name: http
      port: 80
      targetPort: 8080
      protocol: TCP
    - name: https
      port: 443
      targetPort: 8443
      protocol: TCP
EOF
  log_success "Envoy LoadBalancer service 'envoy-lb' created"
fi

# Wait for envoy-lb LoadBalancer to get an external IP
if ! wait_for_condition "Envoy LoadBalancer to get external IP" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get svc -n '${CONTOUR_INGRESS_NAMESPACE}' envoy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '.'"; then
  log_error "Envoy LoadBalancer did not receive an external IP within ${PACKAGE_TIMEOUT}s"
  exit 4
fi

# Store the Contour LB IP for CoreDNS configuration
CONTOUR_LB_IP=$(kubectl get svc -n "${CONTOUR_INGRESS_NAMESPACE}" envoy-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Contour installed and Envoy LoadBalancer IP: ${CONTOUR_LB_IP}"

# Override hostnames with sslip.io when USE_SSLIP_DNS=true
if [[ "${USE_SSLIP_DNS}" == "true" ]]; then
  HARBOR_HOSTNAME=$(construct_sslip_hostname "harbor" "${CONTOUR_LB_IP}")
  GITLAB_HOSTNAME=$(construct_sslip_hostname "gitlab" "${CONTOUR_LB_IP}")
  ARGOCD_HOSTNAME=$(construct_sslip_hostname "argocd" "${CONTOUR_LB_IP}")
  # Override DOMAIN so GitLab global.hosts.domain uses sslip.io
  DOMAIN="${CONTOUR_LB_IP}.sslip.io"
  log_success "sslip.io hostnames: ${HARBOR_HOSTNAME}, ${GITLAB_HOSTNAME}, ${ARGOCD_HOSTNAME}"
  log_success "sslip.io domain: ${DOMAIN}"

  # Re-run prepare_values_files with updated hostnames and domain
  prepare_values_files

  # Phase 3b: Generate self-signed certificates for sslip.io domain
  log_step "3b" "Generating self-signed certificates for *.${DOMAIN}"

  # Remove stale certs from previous runs (domain may have changed)
  rm -rf "${CERT_DIR}"
  mkdir -p "${CERT_DIR}"

  if ! openssl req -x509 -new -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" \
    -days 3650 -subj "/CN=Self-Signed CA"; then
    log_error "Failed to generate self-signed CA certificate"
    exit 3
  fi
  log_success "Self-signed CA certificate generated"

  # Generate dynamic OpenSSL config for the sslip.io domain
  SSLIP_WILDCARD_CNF=$(mktemp /tmp/sslip-wildcard-XXXXXX.cnf)
  cat > "${SSLIP_WILDCARD_CNF}" <<CNFEOF
[req]
default_bits = 2048
prompt = no
default_md = sha256
distinguished_name = dn
req_extensions = v3_req

[dn]
CN = *.${DOMAIN}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = *.${DOMAIN}
DNS.2 = ${DOMAIN}
CNFEOF

  if ! openssl req -new -nodes -newkey rsa:2048 \
    -keyout "${CERT_DIR}/wildcard.key" -out "${CERT_DIR}/wildcard.csr" \
    -config "${SSLIP_WILDCARD_CNF}"; then
    log_error "Failed to generate wildcard certificate CSR"
    rm -f "${SSLIP_WILDCARD_CNF}"
    exit 3
  fi
  log_success "Wildcard certificate CSR generated for *.${DOMAIN}"

  if ! openssl x509 -req -in "${CERT_DIR}/wildcard.csr" \
    -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
    -CAcreateserial -out "${CERT_DIR}/wildcard.crt" \
    -days 3650 -extensions v3_req -extfile "${SSLIP_WILDCARD_CNF}"; then
    log_error "Failed to sign wildcard certificate"
    rm -f "${SSLIP_WILDCARD_CNF}"
    exit 3
  fi
  log_success "Wildcard certificate signed for *.${DOMAIN}"

  rm -f "${SSLIP_WILDCARD_CNF}"

  cat "${CERT_DIR}/wildcard.crt" "${CERT_DIR}/ca.crt" > "${CERT_DIR}/fullchain.crt"
  log_success "Certificates ready in '${CERT_DIR}' for *.${DOMAIN}"
fi

###############################################################################
# Phase 4: Harbor Installation
###############################################################################

log_step 4 "Installing Harbor container registry"

# Create Harbor namespace
kubectl create ns "${HARBOR_NAMESPACE}" 2>/dev/null || true

# Create Harbor TLS secret from wildcard certificate (idempotent)
kubectl create secret tls harbor-tls \
  --cert="${CERT_DIR}/fullchain.crt" \
  --key="${CERT_DIR}/wildcard.key" \
  --namespace "${HARBOR_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Harbor CA secret (idempotent)
kubectl create secret generic harbor-ca \
  --from-file=ca.crt="${CERT_DIR}/ca.crt" \
  --namespace "${HARBOR_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Add Harbor Helm repository
helm repo add harbor https://helm.goharbor.io 2>/dev/null || true
helm repo update 2>/dev/null || true

# Install Harbor via Helm (skip upgrade if already deployed to avoid RWO volume conflicts)
if helm status harbor -n "${HARBOR_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Harbor Helm release already deployed, skipping install"
else
  if ! helm upgrade --install harbor harbor/harbor \
    --namespace "${HARBOR_NAMESPACE}" \
    --create-namespace \
    --version "${HARBOR_VERSION}" \
    --values "${TEMP_DIR}/harbor-values.yaml" \
    --timeout 10m; then
    log_error "Failed to install Harbor via Helm"
    exit 5
  fi
  log_success "Harbor Helm release installed"
fi

# Wait for Harbor pods to reach Running state
if ! wait_for_condition "Harbor pods to be running" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "test \"\$(kubectl get pods -n '${HARBOR_NAMESPACE}' --no-headers 2>/dev/null | grep -cv 'Running\|Completed')\" = '0'"; then
  log_error "Harbor pods did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 5
fi

log_success "Harbor installed and running in namespace '${HARBOR_NAMESPACE}'"

###############################################################################
# Phase 5: CoreDNS Configuration (skipped when USE_SSLIP_DNS=true)
###############################################################################

if [[ "${USE_SSLIP_DNS}" != "true" ]]; then

log_step 5 "Configuring CoreDNS with static host entries"

# Backup current CoreDNS ConfigMap
kubectl get configmap coredns -n kube-system -o yaml > /tmp/coredns-backup.yaml
log_success "CoreDNS ConfigMap backed up to /tmp/coredns-backup.yaml"

# Patch CoreDNS ConfigMap with static host entries for Harbor, GitLab, and ArgoCD
CURRENT_COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')

if echo "${CURRENT_COREFILE}" | grep -q "${GITLAB_HOSTNAME}"; then
  log_success "CoreDNS already contains entry for '${GITLAB_HOSTNAME}', skipping patch"
else
  CLEAN_COREFILE=$(echo "${CURRENT_COREFILE}" | python3 -c '
import re, sys
corefile = sys.stdin.read()
cleaned = re.sub(r"\s*hosts\s*\{[^}]*\}\s*", "\n        ", corefile)
cleaned = re.sub(r"\n(\s*\n)+", "\n", cleaned)
print(cleaned, end="")
')

  HOSTS_BLOCK="hosts {\n            ${CONTOUR_LB_IP} ${HARBOR_HOSTNAME}\n            ${CONTOUR_LB_IP} ${GITLAB_HOSTNAME}\n            ${CONTOUR_LB_IP} ${ARGOCD_HOSTNAME}\n            fallthrough\n        }"

  PATCHED_COREFILE=$(echo "${CLEAN_COREFILE}" | sed "s|ready|${HOSTS_BLOCK}\n        ready|")

  kubectl patch configmap coredns -n kube-system --type merge -p "{
    \"data\": {
      \"Corefile\": $(echo "${PATCHED_COREFILE}" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    }
  }" || {
    log_error "Failed to patch CoreDNS ConfigMap"
    exit 6
  }

  log_success "CoreDNS ConfigMap patched with static entries for '${HARBOR_HOSTNAME}', '${GITLAB_HOSTNAME}', and '${ARGOCD_HOSTNAME}'"
fi

# Restart CoreDNS pods to pick up the new configuration
kubectl rollout restart deployment/coredns -n kube-system

# Wait for CoreDNS pods to be running
if ! wait_for_condition "CoreDNS pods to be running" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "test \"\$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -cv 'Running')\" = '0'"; then
  log_error "CoreDNS pods did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 6
fi

log_success "CoreDNS configured and running with static host entries"

# After CoreDNS restart, the API server may be briefly unreachable.
wait_for_api_server

else
  log_step 5 "Skipping CoreDNS patching (USE_SSLIP_DNS=true — sslip.io resolves externally)"
fi

###############################################################################
# Phase 6: ArgoCD Installation
###############################################################################

log_step 6 "Installing ArgoCD"

# Add ArgoCD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update 2>/dev/null || true

# Install ArgoCD via Helm (skip upgrade if already deployed)
if helm status argocd -n "${ARGOCD_NAMESPACE}" >/dev/null 2>&1; then
  log_success "ArgoCD Helm release already deployed, skipping install"
else
  if ! helm upgrade --install argocd argo/argo-cd \
    --namespace "${ARGOCD_NAMESPACE}" \
    --create-namespace \
    --version "${ARGOCD_VERSION}" \
    --values "${TEMP_DIR}/argocd-values.yaml" \
    --timeout 10m; then
    log_error "Failed to install ArgoCD via Helm"
    exit 7
  fi
  log_success "ArgoCD Helm release installed"
fi

# Wait for ArgoCD server pods to reach Running state
if ! wait_for_condition "ArgoCD server pods to be running" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${ARGOCD_NAMESPACE}' -l app.kubernetes.io/name=argocd-server --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "ArgoCD server pods did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 7
fi

# Retrieve ArgoCD initial admin password from K8s Secret
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n "${ARGOCD_NAMESPACE}" -o jsonpath='{.data.password}' | base64 -d)
log_success "ArgoCD installed and running in namespace '${ARGOCD_NAMESPACE}'"

###############################################################################
# Phase 7: ArgoCD CLI Installation
###############################################################################

log_step 7 "Installing ArgoCD CLI"

if command -v argocd &>/dev/null; then
  log_success "ArgoCD CLI already available in PATH"
else
  # Download ArgoCD CLI from GitHub releases
  if ! curl -sSL -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64; then
    log_error "Failed to download ArgoCD CLI from GitHub releases"
    exit 8
  fi

  chmod +x /tmp/argocd
  export PATH="/tmp:${PATH}"

  # Verify the binary is executable
  if ! command -v argocd &>/dev/null; then
    log_error "ArgoCD CLI binary is not executable after installation"
    exit 8
  fi

  log_success "ArgoCD CLI downloaded and installed to /tmp/argocd"
fi

log_success "ArgoCD CLI is available"

###############################################################################
# Phase 8: Certificate Distribution
###############################################################################

log_step 8 "Distributing certificates to application namespaces"

# Create ArgoCD TLS secret from wildcard certificate
kubectl create secret tls argocd-server-tls \
  --cert="${CERT_DIR}/wildcard.crt" \
  --key="${CERT_DIR}/wildcard.key" \
  --namespace "${ARGOCD_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -
log_success "ArgoCD TLS secret created in namespace '${ARGOCD_NAMESPACE}'"

# Create GitLab namespace with PodSecurity labels
if kubectl get ns "${GITLAB_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${GITLAB_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${GITLAB_NAMESPACE}"
  log_success "Namespace '${GITLAB_NAMESPACE}' created"
fi

kubectl label ns "${GITLAB_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null 2>&1 || true

# Create GitLab Runner namespace with PodSecurity labels
if kubectl get ns "${GITLAB_RUNNER_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${GITLAB_RUNNER_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${GITLAB_RUNNER_NAMESPACE}"
  log_success "Namespace '${GITLAB_RUNNER_NAMESPACE}' created"
fi

kubectl label ns "${GITLAB_RUNNER_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null 2>&1 || true

# Create Harbor CA and GitLab TLS secrets

# Build a CA bundle that includes the self-signed CA plus Let's Encrypt root CAs.
# This ensures the GitLab Runner trusts GitLab regardless of whether the ingress
# uses self-signed certs, Let's Encrypt staging, or Let's Encrypt prod.
CA_BUNDLE_FILE=$(mktemp /tmp/ca-bundle-XXXXXX.crt)
cat "${CERT_DIR}/ca.crt" > "${CA_BUNDLE_FILE}"

# Append Let's Encrypt staging root CA (Fake LE Root X1)
LE_STAGING_CA=$(curl -sSL https://letsencrypt.org/certs/staging/letsencrypt-stg-root-x1.pem 2>/dev/null || true)
if [ -n "${LE_STAGING_CA}" ]; then
  echo "${LE_STAGING_CA}" >> "${CA_BUNDLE_FILE}"
  log_success "Let's Encrypt staging root CA added to CA bundle"
fi

# Append Let's Encrypt prod root CA (ISRG Root X1)
LE_PROD_CA=$(curl -sSL https://letsencrypt.org/certs/isrgrootx1.pem 2>/dev/null || true)
if [ -n "${LE_PROD_CA}" ]; then
  echo "${LE_PROD_CA}" >> "${CA_BUNDLE_FILE}"
  log_success "Let's Encrypt prod root CA added to CA bundle"
fi

# Create Harbor CA secret in GitLab namespace (idempotent)
if ! kubectl create secret generic harbor-ca-cert \
  --from-file=ca.crt="${CA_BUNDLE_FILE}" \
  --namespace "${GITLAB_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -; then
  log_error "Failed to create Harbor CA secret in namespace '${GITLAB_NAMESPACE}'"
  exit 9
fi

# Create Harbor CA secret in GitLab Runner namespace with hostname-based cert key
# The GitLab Runner looks for <hostname>.crt in the certs directory
if ! kubectl create secret generic harbor-ca-cert \
  --from-file=ca.crt="${CA_BUNDLE_FILE}" \
  --from-file="${GITLAB_HOSTNAME}.crt=${CA_BUNDLE_FILE}" \
  --namespace "${GITLAB_RUNNER_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -; then
  log_error "Failed to create Harbor CA secret in namespace '${GITLAB_RUNNER_NAMESPACE}'"
  exit 9
fi

rm -f "${CA_BUNDLE_FILE}"

# Create RBAC for GitLab Runner service account (Kubernetes executor needs pod/secret permissions)
cat <<RBACEOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gitlab-runner
  namespace: ${GITLAB_RUNNER_NAMESPACE}
rules:
- apiGroups: [""]
  resources: ["pods", "secrets", "configmaps", "pods/exec", "pods/attach", "pods/log", "serviceaccounts"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gitlab-runner
  namespace: ${GITLAB_RUNNER_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gitlab-runner
subjects:
- kind: ServiceAccount
  name: default
  namespace: ${GITLAB_RUNNER_NAMESPACE}
RBACEOF
log_success "GitLab Runner RBAC created in namespace '${GITLAB_RUNNER_NAMESPACE}'"

# Create Docker daemon config ConfigMap for DinD insecure registry
# This is mounted into CI job pods so the DinD service trusts Harbor's internal endpoint
HARBOR_INTERNAL="harbor-registry.harbor.svc.cluster.local:5000"
cat <<DAEMONEOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: harbor-docker-config
  namespace: ${GITLAB_RUNNER_NAMESPACE}
data:
  daemon.json: |
    {"insecure-registries": ["${HARBOR_INTERNAL}"]}
DAEMONEOF
log_success "Docker daemon config ConfigMap created with insecure registry '${HARBOR_INTERNAL}'"

# Create GitLab wildcard TLS secret (idempotent)
if ! kubectl create secret tls gitlab-wildcard-tls \
  --cert="${CERT_DIR}/wildcard.crt" \
  --key="${CERT_DIR}/wildcard.key" \
  --namespace "${GITLAB_NAMESPACE}" \
  --dry-run=client -o yaml | kubectl apply -f -; then
  log_error "Failed to create GitLab wildcard TLS secret in namespace '${GITLAB_NAMESPACE}'"
  exit 9
fi

log_success "Certificates distributed to all namespaces for *.${DOMAIN}"

###############################################################################
# Phase 9: GitLab Installation
###############################################################################

log_step 9 "Installing GitLab"

# Add GitLab Helm repository
helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
helm repo update 2>/dev/null || true

# Install GitLab via Helm (skip upgrade if already deployed to avoid RWO volume conflicts)
if helm status gitlab -n "${GITLAB_NAMESPACE}" >/dev/null 2>&1; then
  log_success "GitLab Helm release already deployed, skipping install"
else
  if ! helm upgrade --install gitlab gitlab/gitlab \
    --namespace "${GITLAB_NAMESPACE}" \
    --create-namespace \
    --version "${GITLAB_OPERATOR_VERSION}" \
    --values "${TEMP_DIR}/gitlab-operator-values.yaml" \
    --timeout 10m; then
    log_error "Failed to install GitLab via Helm"
    exit 10
  fi
  log_success "GitLab Helm release installed"
fi

# Wait for GitLab webservice pod to reach Running state
# The chart creates the GitLab instance which takes several minutes to start
if ! wait_for_condition "GitLab webservice pod to be running" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${GITLAB_NAMESPACE}' -l app=webservice --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "GitLab webservice pod did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 10
fi

log_success "GitLab installed and webservice is running in namespace '${GITLAB_NAMESPACE}'"

###############################################################################
# Phase 10: GitLab Image Patching / Harbor Proxy Configuration
###############################################################################

log_step 10 "Configuring Harbor proxy for GitLab images"

# The GitLab Helm values file (gitlab-operator-values.yaml) configures
# Harbor as a proxy cache for DockerHub images. This avoids DockerHub rate limits
# and keeps image traffic inside the lab network.
#
# Patched images (configured in gitlab-operator-values.yaml):
#   postgresql : ${HARBOR_HOSTNAME}/proxy/bitnamilegacy/postgresql:16.6.0
#   redis      : ${HARBOR_HOSTNAME}/proxy/bitnamilegacy/redis:7.2.5
#   minio      : ${HARBOR_HOSTNAME}/proxy/minio/minio:RELEASE.2024-09-22T00-33-43Z
#
# The values file references HARBOR_HOSTNAME as a placeholder. If the Harbor
# proxy cache project is not configured, images will fall back to DockerHub.

# Verify the values file contains Harbor proxy configuration
if grep -q "proxy/" "${TEMP_DIR}/gitlab-operator-values.yaml" 2>/dev/null; then
  log_success "Harbor proxy cache configuration found in '${GITLAB_OPERATOR_VALUES_FILE}'"
else
  log_warn "Harbor proxy cache is not configured in '${GITLAB_OPERATOR_VALUES_FILE}'. DockerHub rate limits may cause image pull failures."
fi

# Verify Harbor hostname is set in the values file
if grep -q "${HARBOR_HOSTNAME}" "${TEMP_DIR}/gitlab-operator-values.yaml" 2>/dev/null; then
  log_success "Harbor hostname reference found in GitLab Operator values"
else
  log_warn "Harbor hostname not found in '${GITLAB_OPERATOR_VALUES_FILE}'. Harbor proxy may not be configured correctly."
  exit 11
fi

log_success "Harbor proxy configuration verified for GitLab images"

###############################################################################
# Phase 11: GitLab Runner Token Retrieval & Runner Installation
###############################################################################

log_step 11 "Installing GitLab Runner"

# Auto-retrieve the runner registration token from the GitLab instance
# if one was not provided via environment variable
if [[ -z "${GITLAB_RUNNER_TOKEN}" ]]; then
  log_success "No GITLAB_RUNNER_TOKEN provided — retrieving from GitLab instance"

  # GitLab 16+ uses the new runner registration API (POST /api/v4/user/runners)
  GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n "${GITLAB_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)

  if [[ -n "${GITLAB_ROOT_PASSWORD}" ]]; then
    # Wait for GitLab API to be ready (retry up to 300s — GitLab Rails takes time to warm up)
    GITLAB_API_TOKEN=""
    ELAPSED=0
    while [ "$ELAPSED" -lt 300 ]; do
      GITLAB_API_TOKEN=$(curl -sSk "https://${GITLAB_HOSTNAME}/oauth/token" \
        -d "grant_type=password&username=root&password=${GITLAB_ROOT_PASSWORD}" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
      if [ -n "${GITLAB_API_TOKEN}" ]; then break; fi
      echo "Waiting for GitLab API... (${ELAPSED}s/300s)"
      sleep 10
      ELAPSED=$((ELAPSED + 10))
    done

    if [[ -n "${GITLAB_API_TOKEN}" ]]; then
      GITLAB_RUNNER_TOKEN=$(curl -sSk -X POST \
        "https://${GITLAB_HOSTNAME}/api/v4/user/runners" \
        -H "Authorization: Bearer ${GITLAB_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d '{"runner_type":"instance_type","description":"vks-runner","tag_list":["kubernetes","privileged"]}' 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)
    fi
  fi

  if [[ -z "${GITLAB_RUNNER_TOKEN}" ]]; then
    log_error "Failed to retrieve GitLab Runner registration token. Set GITLAB_RUNNER_TOKEN manually and re-run."
    exit 12
  fi

  log_success "GitLab Runner registration token retrieved successfully"
fi

# Prepare the runner values file with the token
prepare_runner_values

# Install GitLab Runner via Helm (skip upgrade if already deployed)
if helm status gitlab-runner -n "${GITLAB_RUNNER_NAMESPACE}" >/dev/null 2>&1; then
  log_success "GitLab Runner Helm release already deployed, skipping install"
else
  if ! helm upgrade --install gitlab-runner gitlab/gitlab-runner \
    --namespace "${GITLAB_RUNNER_NAMESPACE}" \
    --create-namespace \
    --version "${GITLAB_RUNNER_VERSION}" \
    --values "${TEMP_DIR}/gitlab-runner-values.yaml" \
    --timeout 10m; then
    log_error "Failed to install GitLab Runner via Helm"
    exit 12
  fi
  log_success "GitLab Runner Helm release installed"
fi

# Wait for GitLab Runner pod to reach Running state
if ! wait_for_condition "GitLab Runner pod to be running" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${GITLAB_RUNNER_NAMESPACE}' -l app=gitlab-runner --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "GitLab Runner pod did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 12
fi

log_success "GitLab Runner installed and running in namespace '${GITLAB_RUNNER_NAMESPACE}'"

###############################################################################
# Phase 11b: Disable GitLab Public Sign-Up (Security Hardening)
###############################################################################

# The GitLab Helm chart does not expose a values key for disabling sign-up.
# It is an application-level setting stored in the GitLab database, so we
# use the GitLab API to disable it after the instance is running.

log_step "11b" "Disabling GitLab public sign-up registration"

# Ensure we have the root password (may already be set from runner token retrieval)
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n "${GITLAB_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi

if [[ -n "${GITLAB_ROOT_PASSWORD}" ]]; then
  # Obtain an OAuth access token for the root user
  SIGNUP_API_TOKEN=$(curl -sSk "https://${GITLAB_HOSTNAME}/oauth/token" \
    -d "grant_type=password&username=root&password=${GITLAB_ROOT_PASSWORD}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)

  if [[ -n "${SIGNUP_API_TOKEN}" ]]; then
    # Disable public sign-up via the Application Settings API
    SIGNUP_RESULT=$(curl -sSk -X PUT \
      "https://${GITLAB_HOSTNAME}/api/v4/application/settings?signup_enabled=false" \
      -H "Authorization: Bearer ${SIGNUP_API_TOKEN}" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('signup_enabled','unknown'))" 2>/dev/null || true)

    if [[ "${SIGNUP_RESULT}" == "False" || "${SIGNUP_RESULT}" == "false" ]]; then
      log_success "GitLab public sign-up disabled via API"
    else
      log_warn "GitLab sign-up API returned: ${SIGNUP_RESULT}. Verify manually in Admin > Settings > General > Sign-up restrictions."
    fi
  else
    log_warn "Could not obtain GitLab API token. Disable sign-up manually in Admin > Settings > General > Sign-up restrictions."
  fi
else
  log_warn "GitLab root password not found. Disable sign-up manually in Admin > Settings > General > Sign-up restrictions."
fi

###############################################################################
# Phase 12: ArgoCD Cluster Registration
###############################################################################

log_step 12 "Registering cluster with ArgoCD"

# All ArgoCD CLI commands are executed inside the ArgoCD server pod via
# kubectl exec. This avoids kubectl port-forward, which suffers from
# persistent "connection reset by peer" errors on some VKS clusters due to
# stale CNI network namespace references in the kubelet.

# Resolve the ArgoCD server pod name
ARGOCD_POD=$(kubectl get pod -n "${ARGOCD_NAMESPACE}" \
  -l app.kubernetes.io/name=argocd-server \
  -o jsonpath='{.items[0].metadata.name}')

# Helper: run an argocd CLI command inside the server pod.
# The pod already contains the argocd binary and can reach localhost:8080.
argocd_exec() {
  kubectl exec -n "${ARGOCD_NAMESPACE}" "${ARGOCD_POD}" -- sh -c "$*"
}

# Authenticate to ArgoCD inside the pod
if ! argocd_exec "argocd login localhost:8080 \
  --username admin \
  --password '${ARGOCD_PASSWORD}' \
  --plaintext --insecure"; then
  log_error "Failed to authenticate to ArgoCD"
  exit 13
fi
log_success "Authenticated to ArgoCD via kubectl exec"

# Copy the kubeconfig into the pod so argocd cluster add can read it
kubectl cp "${KUBECONFIG_FILE}" "${ARGOCD_NAMESPACE}/${ARGOCD_POD}:/tmp/kubeconfig.yaml"

# Get the cluster context from the kubeconfig
CLUSTER_CONTEXT=$(kubectl config current-context)

# Check if the cluster is already registered with ArgoCD
if argocd_exec "argocd cluster list" 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  log_success "Cluster '${CLUSTER_NAME}' is already registered with ArgoCD, skipping registration"
else
  # Register the VKS cluster with ArgoCD
  if ! argocd_exec "argocd cluster add '${CLUSTER_CONTEXT}' \
    --name '${CLUSTER_NAME}' \
    --kubeconfig /tmp/kubeconfig.yaml \
    --yes"; then
    log_error "Failed to register cluster '${CLUSTER_NAME}' with ArgoCD"
    exit 13
  fi
  log_success "Cluster '${CLUSTER_NAME}' registered with ArgoCD"
fi

# Wait for the cluster to be healthy in ArgoCD
if ! wait_for_condition "ArgoCD cluster '${CLUSTER_NAME}' to be healthy" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl exec -n '${ARGOCD_NAMESPACE}' '${ARGOCD_POD}' -- argocd cluster list 2>/dev/null | grep '${CLUSTER_NAME}' | grep -qi 'successful\\|ok\\|healthy\\|unknown'"; then
  log_error "ArgoCD cluster '${CLUSTER_NAME}' did not reach healthy state within ${PACKAGE_TIMEOUT}s"
  exit 13
fi

log_success "Cluster '${CLUSTER_NAME}' registered and healthy in ArgoCD"

###############################################################################
# Phase 13: ArgoCD Application Bootstrap
###############################################################################

log_step 13 "Bootstrapping ArgoCD application for Microservices Demo"

# Pre-create the application namespace with privileged PodSecurity labels.
# The microservices-demo manifests do not set seccompProfile, which violates
# the default "restricted" PodSecurity standard on VKS clusters.
kubectl create ns "${APP_NAMESPACE}" 2>/dev/null || true
kubectl label ns "${APP_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null 2>&1 || true
log_success "Namespace '${APP_NAMESPACE}' labelled with privileged PodSecurity"

# Check if the ArgoCD Application already exists
if argocd_exec "argocd app get microservices-demo" >/dev/null 2>&1; then
  log_success "ArgoCD Application 'microservices-demo' already exists, skipping creation"
else
  # Apply the ArgoCD Application manifest
  if ! kubectl apply -f "${TEMP_DIR}/argocd-microservices-demo.yaml"; then
    log_error "Failed to apply ArgoCD Application manifest from '${ARGOCD_APP_MANIFEST}'"
    exit 14
  fi
  log_success "ArgoCD Application 'microservices-demo' created from '${ARGOCD_APP_MANIFEST}'"
fi

# Wait for the ArgoCD application to reach Synced and Healthy state
if ! wait_for_condition "ArgoCD application 'microservices-demo' to be Synced and Healthy" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl exec -n '${ARGOCD_NAMESPACE}' '${ARGOCD_POD}' -- argocd app get microservices-demo 2>/dev/null | tee /tmp/argocd-app-status | grep -q 'Healthy' && grep -q 'Synced' /tmp/argocd-app-status"; then
  log_error "ArgoCD application 'microservices-demo' did not reach Synced/Healthy state within ${PACKAGE_TIMEOUT}s"
  exit 14
fi

log_success "ArgoCD application 'microservices-demo' is Synced and Healthy"

###############################################################################
# Phase 14: Microservices Demo Verification
###############################################################################

log_step 14 "Verifying Microservices Demo deployment"

echo ""
echo "--- Microservices Demo Pods ---"
kubectl get pods -n "${APP_NAMESPACE}" 2>/dev/null || true
echo ""

# Check pods for all 11 microservices
EXPECTED_SERVICES=(
  "adservice"
  "cartservice"
  "checkoutservice"
  "currencyservice"
  "emailservice"
  "frontend"
  "loadgenerator"
  "paymentservice"
  "productcatalogservice"
  "recommendationservice"
  "shippingservice"
)

ALL_RUNNING=true
for service in "${EXPECTED_SERVICES[@]}"; do
  if kubectl get pods -n "${APP_NAMESPACE}" --no-headers 2>/dev/null | grep -q "${service}.*Running"; then
    log_success "Service '${service}' is running"
  else
    log_warn "Service '${service}' is not in Running state"
    ALL_RUNNING=false
  fi
done

if [[ "${ALL_RUNNING}" == "false" ]]; then
  log_warn "Some microservices are not yet running. They may still be starting up."
  log_warn "Check pod status with: kubectl get pods -n ${APP_NAMESPACE}"
fi

# Display frontend endpoint
echo ""
echo "--- Frontend Access ---"
FRONTEND_LB_IP=""
if [[ "${USE_SSLIP_DNS}" != "true" ]]; then
  # Wait for frontend-external LoadBalancer IP. The service is created by ArgoCD
  # sync moments before this phase runs, so NSX may need up to several minutes
  # to assign an external IP. Poll for up to 5 minutes (60 × 5s).
  for i in $(seq 1 60); do
    FRONTEND_LB_IP=$(kubectl get svc -n "${APP_NAMESPACE}" frontend-external -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "${FRONTEND_LB_IP}" ]]; then
      break
    fi
    if [[ "$((i % 6))" -eq 1 ]]; then
      echo "  Waiting for frontend-external LoadBalancer IP... ($(( (i-1)*5 ))s elapsed)"
    fi
    sleep 5
  done

  if [[ -n "${FRONTEND_LB_IP}" ]]; then
    log_success "Frontend external LoadBalancer IP: ${FRONTEND_LB_IP}"
    echo "  Open http://${FRONTEND_LB_IP} in your browser."
  else
    FRONTEND_SVC=$(kubectl get svc -n "${APP_NAMESPACE}" frontend -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [[ -n "${FRONTEND_SVC}" ]]; then
      log_success "Frontend service ClusterIP: ${FRONTEND_SVC}"
      echo "  To access the Online Boutique UI, run:"
      echo "    kubectl --kubeconfig=${KUBECONFIG_FILE} port-forward -n ${APP_NAMESPACE} svc/frontend 8080:80"
      echo "  Then open http://localhost:8080 in your browser."
    else
      log_warn "Frontend service not found in namespace '${APP_NAMESPACE}'"
    fi
  fi
else
  log_success "USE_SSLIP_DNS=true — frontend uses ClusterIP + sslip.io Ingress (no LoadBalancer needed)"
fi

log_success "Microservices Demo verification complete"

###############################################################################
# Phase 14b: Let's Encrypt TLS Ingress (when USE_SSLIP_DNS=true)
#
# The Helm charts (Harbor, GitLab, ArgoCD) manage their own internal TLS
# using the self-signed wildcard cert. This phase creates separate Contour
# Ingress resources with cert-manager annotations for the external-facing
# hostnames. Traffic from the internet gets trusted Let's Encrypt TLS at
# the Envoy proxy, then Envoy proxies to the backend over internal TLS.
###############################################################################

if [[ "${USE_SSLIP_DNS}" == "true" ]]; then
  log_step "14b" "Creating Let's Encrypt TLS Ingress resources for external access"

  # Check if ClusterIssuer is ready
  TLS_ENABLED="false"
  if check_cluster_issuer_ready "${CLUSTER_ISSUER_NAME}" 2>/dev/null; then
    TLS_ENABLED="true"
    log_success "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is Ready — creating Ingress with TLS"
  else
    log_warn "ClusterIssuer '${CLUSTER_ISSUER_NAME}' not ready — creating Ingress without TLS"
  fi

  # Delete Helm-managed Ingress resources that conflict with our Let's Encrypt ones.
  # ArgoCD and GitLab Helm charts create their own Ingress with self-signed TLS.
  # Contour can't serve two Ingress objects for the same host — the Helm one wins.
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    kubectl delete ingress argocd-server -n "${ARGOCD_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete ingress gitlab-webservice-default -n "${GITLAB_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    kubectl delete ingress harbor-ingress -n "${HARBOR_NAMESPACE}" --ignore-not-found 2>/dev/null || true
    log_success "Helm-managed Ingress resources deleted (ArgoCD, GitLab, Harbor) — Let's Encrypt Ingress will take over"
  fi

  # Harbor Ingress with Let's Encrypt
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: harbor-letsencrypt-ingress
  namespace: ${HARBOR_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER_NAME}"
spec:
  ingressClassName: contour
  tls:
    - hosts:
        - ${HARBOR_HOSTNAME}
      secretName: harbor-letsencrypt-tls
  rules:
    - host: ${HARBOR_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: harbor-portal
                port:
                  number: 80
          - path: /api/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /service/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /v2/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /chartrepo/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
          - path: /c/
            pathType: Prefix
            backend:
              service:
                name: harbor-core
                port:
                  number: 80
EOF
    log_success "Harbor Let's Encrypt Ingress created for ${HARBOR_HOSTNAME}"
  fi

  # ArgoCD Ingress with Let's Encrypt
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-letsencrypt-ingress
  namespace: ${ARGOCD_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER_NAME}"
spec:
  ingressClassName: contour
  tls:
    - hosts:
        - ${ARGOCD_HOSTNAME}
      secretName: argocd-letsencrypt-tls
  rules:
    - host: ${ARGOCD_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF
    log_success "ArgoCD Let's Encrypt Ingress created for ${ARGOCD_HOSTNAME}"
  fi

  # GitLab Ingress with Let's Encrypt
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gitlab-letsencrypt-ingress
  namespace: ${GITLAB_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER_NAME}"
spec:
  ingressClassName: contour
  tls:
    - hosts:
        - ${GITLAB_HOSTNAME}
      secretName: gitlab-letsencrypt-tls
  rules:
    - host: ${GITLAB_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: gitlab-webservice-default
                port:
                  number: 8181
EOF
    log_success "GitLab Let's Encrypt Ingress created for ${GITLAB_HOSTNAME}"
  fi

  # Online Boutique (Microservices Demo) Ingress with Let's Encrypt
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    BOUTIQUE_HOSTNAME=$(construct_sslip_hostname "boutique" "${CONTOUR_LB_IP}")
    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: boutique-letsencrypt-ingress
  namespace: ${APP_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER_NAME}"
spec:
  ingressClassName: contour
  tls:
    - hosts:
        - ${BOUTIQUE_HOSTNAME}
      secretName: boutique-letsencrypt-tls
  rules:
    - host: ${BOUTIQUE_HOSTNAME}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: frontend
                port:
                  number: 80
EOF
    log_success "Online Boutique Let's Encrypt Ingress created for ${BOUTIQUE_HOSTNAME}"
  fi

  # Wait for certificates to be issued
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    log_success "Waiting for Let's Encrypt certificates to be issued..."
    for CERT_NAME in harbor-letsencrypt-tls argocd-letsencrypt-tls gitlab-letsencrypt-tls boutique-letsencrypt-tls; do
      CERT_NS="default"
      case "${CERT_NAME}" in
        harbor*) CERT_NS="${HARBOR_NAMESPACE}" ;;
        argocd*) CERT_NS="${ARGOCD_NAMESPACE}" ;;
        gitlab*) CERT_NS="${GITLAB_NAMESPACE}" ;;
        boutique*) CERT_NS="${APP_NAMESPACE}" ;;
      esac
      if wait_for_certificate "${CERT_NAME}" "${CERT_NS}" "${CERT_WAIT_TIMEOUT}"; then
        log_success "Certificate '${CERT_NAME}' is Ready"
      else
        log_warn "Certificate '${CERT_NAME}' not ready within ${CERT_WAIT_TIMEOUT}s — HTTPS may use self-signed cert"
      fi
    done
  fi

  log_success "Let's Encrypt TLS Ingress resources created"
fi

###############################################################################
# Phase 16: Harbor CI Project & GitLab Project Creation
#
# Creates the Harbor project for CI-built images, creates a GitLab project
# with the microservices-demo Kustomize overlay, Dockerfile, .gitlab-ci.yml,
# and demo-config.yaml, then pushes all files to the GitLab default branch.
###############################################################################

log_step 16 "Creating Harbor CI project and GitLab project for CI/CD pipeline"

# --- 16a: Create Harbor CI project via REST API ---

HARBOR_API_URL="https://${HARBOR_HOSTNAME}/api/v2.0"

# Check if Harbor CI project already exists
HARBOR_PROJECT_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "admin:${HARBOR_ADMIN_PASSWORD}" \
  "${HARBOR_API_URL}/projects?name=${HARBOR_CI_PROJECT}" -k)

HARBOR_PROJECT_LIST=$(curl -s \
  -u "admin:${HARBOR_ADMIN_PASSWORD}" \
  "${HARBOR_API_URL}/projects?name=${HARBOR_CI_PROJECT}" -k)

# Check if the project name matches exactly in the response
if echo "${HARBOR_PROJECT_LIST}" | python3 -c "
import sys, json
projects = json.load(sys.stdin)
sys.exit(0 if any(p['name'] == '${HARBOR_CI_PROJECT}' for p in projects) else 1)
" 2>/dev/null; then
  log_success "Harbor CI project '${HARBOR_CI_PROJECT}' already exists, skipping creation"
else
  HARBOR_CREATE_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -u "admin:${HARBOR_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"project_name":"'"${HARBOR_CI_PROJECT}"'","public":true}' \
    "${HARBOR_API_URL}/projects" -k)

  if [[ "${HARBOR_CREATE_RESPONSE}" == "201" || "${HARBOR_CREATE_RESPONSE}" == "409" ]]; then
    log_success "Harbor CI project '${HARBOR_CI_PROJECT}' created"
  else
    log_error "Failed to create Harbor CI project '${HARBOR_CI_PROJECT}' (HTTP ${HARBOR_CREATE_RESPONSE})"
    exit 16
  fi
fi

# --- 16b: Create GitLab personal access token for API operations ---

# Retrieve GitLab root password from K8s secret (reuse pattern from Phase 11)
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n "${GITLAB_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
fi

if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  log_error "Failed to retrieve GitLab root password from K8s secret 'gitlab-gitlab-initial-root-password'"
  exit 16
fi

# Create a personal access token for the root user via GitLab API
# First, obtain an OAuth token using the root password (retry up to 60s — GitLab may still be warming up)
GITLAB_OAUTH_TOKEN=""
ELAPSED=0
while [ "$ELAPSED" -lt 60 ]; do
  GITLAB_OAUTH_TOKEN=$(curl -sSk "https://${GITLAB_HOSTNAME}/oauth/token" \
    -d "grant_type=password&username=root&password=${GITLAB_ROOT_PASSWORD}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || true)
  if [ -n "${GITLAB_OAUTH_TOKEN}" ]; then
    break
  fi
  echo "Waiting for GitLab OAuth endpoint... (${ELAPSED}s/60s)"
  sleep 10
  ELAPSED=$((ELAPSED + 10))
done

if [[ -z "${GITLAB_OAUTH_TOKEN}" ]]; then
  log_error "Failed to obtain GitLab OAuth token for root user after 60s"
  exit 16
fi

# Create a PAT with api scope for subsequent operations
GITLAB_PAT_RESPONSE=$(curl -sSk -X POST \
  "https://${GITLAB_HOSTNAME}/api/v4/users/1/personal_access_tokens" \
  -H "Authorization: Bearer ${GITLAB_OAUTH_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"name":"deploy-cicd-pat","scopes":["api","write_repository"],"expires_at":"'"$(date -d '+1 year' '+%Y-%m-%d' 2>/dev/null || date -v+1y '+%Y-%m-%d' 2>/dev/null)"'"}' 2>/dev/null || true)

GITLAB_API_PAT=$(echo "${GITLAB_PAT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)

if [[ -z "${GITLAB_API_PAT}" ]]; then
  # Fallback: use the OAuth token directly for API operations
  log_warn "Could not create GitLab PAT, falling back to OAuth token for API operations"
  GITLAB_API_PAT="${GITLAB_OAUTH_TOKEN}"
fi

log_success "GitLab API token obtained for root user"

# --- 16c: Create GitLab project via REST API ---

# Check if project already exists
GITLAB_PROJECT_ID=$(curl -sSk \
  "https://${GITLAB_HOSTNAME}/api/v4/projects?search=${GITLAB_PROJECT_NAME}" \
  -H "PRIVATE-TOKEN: ${GITLAB_API_PAT}" 2>/dev/null \
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
  log_success "GitLab project '${GITLAB_PROJECT_NAME}' already exists (ID: ${GITLAB_PROJECT_ID}), skipping creation"
else
  GITLAB_PROJECT_RESPONSE=$(curl -sSk -X POST \
    "https://${GITLAB_HOSTNAME}/api/v4/projects" \
    -H "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
    -H "Content-Type: application/json" \
    -d '{"name":"'"${GITLAB_PROJECT_NAME}"'","visibility":"public","initialize_with_readme":false}' 2>/dev/null)

  GITLAB_PROJECT_ID=$(echo "${GITLAB_PROJECT_RESPONSE}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

  if [[ -z "${GITLAB_PROJECT_ID}" ]]; then
    log_error "Failed to create GitLab project '${GITLAB_PROJECT_NAME}'"
    log_error "API response: ${GITLAB_PROJECT_RESPONSE}"
    exit 16
  fi

  log_success "GitLab project '${GITLAB_PROJECT_NAME}' created (ID: ${GITLAB_PROJECT_ID})"
fi

# --- 16d: Generate and push CI/CD files to GitLab project ---

CICD_TEMP_DIR=$(mktemp -d)
log_success "CI/CD temp directory created at '${CICD_TEMP_DIR}'"

# Clone the GitLab project (may be empty)
GIT_SSL_NO_VERIFY=true git clone \
  "https://root:${GITLAB_API_PAT}@${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}.git" \
  "${CICD_TEMP_DIR}/repo" 2>/dev/null || {
  # If clone fails (empty repo), initialize manually
  mkdir -p "${CICD_TEMP_DIR}/repo"
  cd "${CICD_TEMP_DIR}/repo"
  git init
  git remote add origin "https://root:${GITLAB_API_PAT}@${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}.git"
  cd - >/dev/null
}

cd "${CICD_TEMP_DIR}/repo"

# Configure git for this repo
git config user.email "admin@${DOMAIN}"
git config user.name "Deploy Script"
git config http.sslVerify false

# Copy kubernetes-manifests.yaml from the existing overlay
cp "$(dirname "$0")/microservices-overlay/kubernetes-manifests.yaml" \
  "${CICD_TEMP_DIR}/repo/kubernetes-manifests.yaml"

# Generate kustomization.yaml (GitLab version with images section for Harbor CI)
cat > "${CICD_TEMP_DIR}/repo/kustomization.yaml" <<KUSTOMEOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - kubernetes-manifests.yaml

patches:
  - target:
      kind: Service
      name: frontend-external
    patch: |
      - op: replace
        path: /spec/type
        value: ClusterIP

images:
  - name: us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend
    newName: harbor-registry.harbor.svc.cluster.local:5000/${HARBOR_CI_PROJECT}/frontend
    newTag: v0.10.5
KUSTOMEOF

# Generate .gitlab-ci.yml
cat > "${CICD_TEMP_DIR}/repo/.gitlab-ci.yml" <<'CIEOF'
stages:
  - build
  - update-manifests

variables:
  DOCKER_TLS_CERTDIR: ""
  HARBOR_HOST: "PLACEHOLDER_HARBOR_HOST"
  IMAGE_NAME: "PLACEHOLDER_IMAGE_NAME"

build:
  stage: build
  image: docker:24-cli
  services:
    - docker:24-dind
  before_script:
    - 'until docker info >/dev/null 2>&1; do sleep 1; done'
    - 'docker login -u admin -p "${HARBOR_PASSWORD}" "${HARBOR_HOST}"'
  script:
    - "BANNER_TEXT=$(grep 'banner_text:' demo-config.yaml | sed 's/banner_text:[[:space:]]*\"\\(.*\\)\"/\\1/' | sed 's/banner_text:[[:space:]]*//')"
    - 'docker build --build-arg FRONTEND_MESSAGE="${BANNER_TEXT}" -t "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}" .'
    - 'docker push "${IMAGE_NAME}:${CI_COMMIT_SHORT_SHA}"'

update-manifests:
  stage: update-manifests
  image: alpine:3.19
  variables:
    GIT_SSL_NO_VERIFY: "true"
  before_script:
    - apk add --no-cache git sed
  script:
    - 'sed -i "s|newTag:.*|newTag: ${CI_COMMIT_SHORT_SHA}|" kustomization.yaml'
    - 'git config user.email "ci@gitlab.local"'
    - 'git config user.name "GitLab CI"'
    - git add kustomization.yaml
    - 'if ! git diff --cached --quiet; then git commit -m "Update frontend image to ${CI_COMMIT_SHORT_SHA} [skip ci]"; fi'
    - 'git push https://root:${GITLAB_PUSH_TOKEN}@${CI_SERVER_HOST}/root/${CI_PROJECT_NAME}.git HEAD:main'
CIEOF

# Substitute placeholder values into .gitlab-ci.yml
# CI jobs run as pods and use CoreDNS — sslip.io hostname works for docker login/push
HARBOR_INTERNAL="harbor-registry.harbor.svc.cluster.local:5000"
sed -i \
  -e "s|PLACEHOLDER_HARBOR_HOST|${HARBOR_HOSTNAME}|g" \
  -e "s|PLACEHOLDER_IMAGE_NAME|${HARBOR_HOSTNAME}/${HARBOR_CI_PROJECT}/frontend|g" \
  "${CICD_TEMP_DIR}/repo/.gitlab-ci.yml"

# Set GitLab CI/CD variables for sensitive values (Harbor password, GitLab push token)
# These are stored as project-level CI/CD variables, not hardcoded in .gitlab-ci.yml
curl -sSk -X POST \
  "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/variables" \
  -H "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
  -H "Content-Type: application/json" \
  -d '{"key":"HARBOR_PASSWORD","value":"'"${HARBOR_ADMIN_PASSWORD}"'","masked":true}' 2>/dev/null || true

curl -sSk -X POST \
  "https://${GITLAB_HOSTNAME}/api/v4/projects/${GITLAB_PROJECT_ID}/variables" \
  -H "PRIVATE-TOKEN: ${GITLAB_API_PAT}" \
  -H "Content-Type: application/json" \
  -d '{"key":"GITLAB_PUSH_TOKEN","value":"'"${GITLAB_API_PAT}"'","masked":true}' 2>/dev/null || true

log_success "GitLab CI/CD variables set for Harbor password and push token"

# Generate Dockerfile for the frontend image
cat > "${CICD_TEMP_DIR}/repo/Dockerfile" <<'DOCKEREOF'
FROM us-central1-docker.pkg.dev/google-samples/microservices-demo/frontend:v0.10.5
ARG FRONTEND_MESSAGE=""
ENV FRONTEND_MESSAGE=${FRONTEND_MESSAGE}
DOCKEREOF

# Generate demo-config.yaml
cat > "${CICD_TEMP_DIR}/repo/demo-config.yaml" <<DEMOEOF
# Demo Configuration — Edit this file in GitLab's web UI to trigger the CI/CD pipeline.
# Change the banner_text to display a message on the Online Boutique frontend.
banner_text: "${DEMO_BANNER_TEXT}"
banner_color: "#C2185B"
DEMOEOF

# Commit and push all files
git add -A
if git diff --cached --quiet 2>/dev/null; then
  log_success "GitLab project '${GITLAB_PROJECT_NAME}' already contains CI/CD files, skipping push"
else
  git commit -m "Initial CI/CD pipeline setup

- kustomization.yaml: Kustomize overlay with Harbor CI image reference
- kubernetes-manifests.yaml: Upstream microservices-demo manifests
- .gitlab-ci.yml: Build and update-manifests pipeline stages
- Dockerfile: Frontend image with configurable banner message
- demo-config.yaml: Demo banner configuration"

  if ! GIT_SSL_NO_VERIFY=true git push -u origin HEAD:main 2>/dev/null; then
    # Try pushing to master if main doesn't work
    if ! GIT_SSL_NO_VERIFY=true git push -u origin HEAD:master 2>/dev/null; then
      log_error "Failed to push CI/CD files to GitLab project '${GITLAB_PROJECT_NAME}'"
      cd - >/dev/null
      rm -rf "${CICD_TEMP_DIR}"
      exit 16
    fi
  fi

  log_success "CI/CD files pushed to GitLab project '${GITLAB_PROJECT_NAME}'"
fi

cd - >/dev/null
rm -rf "${CICD_TEMP_DIR}"

log_success "Phase 16 complete — Harbor CI project and GitLab project ready"

###############################################################################
# Phase 17: ArgoCD Re-Point to GitLab
#
# Adds the GitLab repository credentials to ArgoCD and patches the existing
# ArgoCD Application to point at the GitLab project instead of GitHub.
###############################################################################

log_step 17 "Re-pointing ArgoCD to GitLab repository"

# --- 17a: Add ArgoCD repository credentials for GitLab ---

GITLAB_REPO_URL="https://${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}.git"

# Check if the GitLab repo is already registered with ArgoCD
if argocd_exec "argocd repo list" 2>/dev/null | grep -q "${GITLAB_HOSTNAME}"; then
  log_success "ArgoCD already has credentials for '${GITLAB_HOSTNAME}', skipping repo add"
else
  if ! argocd_exec "argocd repo add '${GITLAB_REPO_URL}' \
    --username root \
    --password '${GITLAB_ROOT_PASSWORD}' \
    --insecure-skip-server-verification"; then
    log_error "Failed to add GitLab repository '${GITLAB_REPO_URL}' to ArgoCD"
    exit 17
  fi
  log_success "GitLab repository credentials added to ArgoCD"
fi

# --- 17b: Patch ArgoCD Application source to GitLab ---

if ! kubectl patch application microservices-demo -n "${ARGOCD_NAMESPACE}" --type merge -p '{
  "spec": {
    "source": {
      "repoURL": "'"${GITLAB_REPO_URL}"'",
      "path": ".",
      "targetRevision": "main"
    }
  }
}'; then
  log_error "Failed to patch ArgoCD Application 'microservices-demo' to point to GitLab"
  exit 17
fi
log_success "ArgoCD Application 'microservices-demo' patched to source from GitLab"

# Wait for ArgoCD Application to reach Synced and Healthy status after re-point
if ! wait_for_condition "ArgoCD application 'microservices-demo' to be Synced and Healthy (GitLab source)" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl exec -n '${ARGOCD_NAMESPACE}' '${ARGOCD_POD}' -- argocd app get microservices-demo 2>/dev/null | tee /tmp/argocd-app-status | grep -q 'Healthy' && grep -q 'Synced' /tmp/argocd-app-status"; then
  log_error "ArgoCD application 'microservices-demo' did not reach Synced/Healthy state within ${PACKAGE_TIMEOUT}s after re-pointing to GitLab"
  exit 17
fi

log_success "Phase 17 complete — ArgoCD now watches GitLab repository '${GITLAB_REPO_URL}'"

###############################################################################
# Phase 18: Pipeline Verification & Demo Instructions
#
# Verifies the CI/CD pipeline is ready: GitLab Runner registered, ArgoCD
# Application synced with GitLab source, and frontend pod running.
# All checks are non-fatal (log_warn) — the pipeline may need a few minutes
# to fully converge after initial setup.
###############################################################################

log_step 18 "Verifying CI/CD pipeline readiness"

# --- 18a: Check GitLab Runner is registered ---
RUNNER_CHECK=$(curl -sSk \
  "https://${GITLAB_HOSTNAME}/api/v4/runners/all" \
  -H "PRIVATE-TOKEN: ${GITLAB_API_PAT}" 2>/dev/null || true)

if echo "${RUNNER_CHECK}" | python3 -c "import sys,json; runners=json.load(sys.stdin); sys.exit(0 if len(runners)>0 else 1)" 2>/dev/null; then
  log_success "GitLab Runner is registered and available"
else
  log_warn "No GitLab Runner detected — the runner may still be registering. Check https://${GITLAB_HOSTNAME}/admin/runners"
fi

# --- 18b: Check ArgoCD Application is Synced/Healthy with GitLab source ---
ARGOCD_APP_STATUS=$(kubectl exec -n "${ARGOCD_NAMESPACE}" "${ARGOCD_POD}" -- \
  argocd app get microservices-demo 2>/dev/null || true)

if echo "${ARGOCD_APP_STATUS}" | grep -q "Healthy" && echo "${ARGOCD_APP_STATUS}" | grep -q "Synced"; then
  log_success "ArgoCD Application 'microservices-demo' is Synced and Healthy with GitLab source"
else
  log_warn "ArgoCD Application 'microservices-demo' is not yet Synced/Healthy — it may still be reconciling"
fi

# --- 18c: Check frontend pod is running ---
FRONTEND_POD_COUNT=$(kubectl get pods -n "${APP_NAMESPACE}" -l app=frontend --no-headers 2>/dev/null | grep -c "Running" || true)

if [[ "${FRONTEND_POD_COUNT}" -gt 0 ]]; then
  log_success "Frontend pod is running in namespace '${APP_NAMESPACE}'"
else
  log_warn "Frontend pod is not running in namespace '${APP_NAMESPACE}' — ArgoCD may still be syncing"
fi

log_success "Phase 18 complete — pipeline verification finished"

###############################################################################
# Phase 15: Summary Banner
###############################################################################

log_step 15 "Deployment summary"

# Retrieve GitLab root password for the summary (may already be set from Phase 11)
if [[ -z "${GITLAB_ROOT_PASSWORD:-}" ]]; then
  GITLAB_ROOT_PASSWORD=$(kubectl get secret gitlab-gitlab-initial-root-password -n "${GITLAB_NAMESPACE}" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "(secret not found)"  )
fi

echo ""
echo "============================================="
echo "  VCF 9 Deploy GitOps — Deployment Complete"
echo "============================================="
echo "  Cluster:              ${CLUSTER_NAME}"
echo "  Domain:               ${DOMAIN}"
echo "  Contour:              VKS package (ns: ${CONTOUR_INGRESS_NAMESPACE})"
echo "  Harbor:               v${HARBOR_VERSION} (ns: ${HARBOR_NAMESPACE})"
echo "  ArgoCD:               v${ARGOCD_VERSION} (ns: ${ARGOCD_NAMESPACE})"
echo "  GitLab Operator:      v${GITLAB_OPERATOR_VERSION} (ns: ${GITLAB_NAMESPACE})"
echo "  GitLab Runner:        v${GITLAB_RUNNER_VERSION} (ns: ${GITLAB_RUNNER_NAMESPACE})"
echo "  Microservices Demo:   ns: ${APP_NAMESPACE}"
echo "  Helm Charts Repo:     ${HELM_CHARTS_REPO_URL}"
echo "============================================="
echo ""
echo "  Infrastructure deployed (self-contained):"
echo "    - Contour ingress controller (VKS package, shared with Deploy Metrics)"
echo "    - Harbor container registry (Helm chart v${HARBOR_VERSION})"
echo "    - ArgoCD GitOps controller (Helm chart v${ARGOCD_VERSION})"
echo "    - Self-signed CA and wildcard certificates (${CERT_DIR})"
echo ""
echo "  Application components deployed:"
echo "    - GitLab Operator (Helm chart v${GITLAB_OPERATOR_VERSION})"
echo "    - GitLab Runner (Helm chart v${GITLAB_RUNNER_VERSION})"
echo "    - Harbor CA certificates (in ${GITLAB_NAMESPACE}, ${GITLAB_RUNNER_NAMESPACE})"
echo "    - GitLab wildcard TLS certificate (in ${GITLAB_NAMESPACE})"
echo "    - CoreDNS static entries (${HARBOR_HOSTNAME}, ${GITLAB_HOSTNAME}, ${ARGOCD_HOSTNAME})"
echo "    - ArgoCD cluster registration (${CLUSTER_NAME})"
echo "    - ArgoCD Application (microservices-demo)"
echo "    - Microservices Demo (11 services in ${APP_NAMESPACE})"
echo ""
echo "  Contour LoadBalancer IP: ${CONTOUR_LB_IP}"
if [[ -n "${FRONTEND_LB_IP}" && "${FRONTEND_LB_IP}" != "${CONTOUR_LB_IP}" ]]; then
  echo "  Frontend LoadBalancer IP: ${FRONTEND_LB_IP}"
fi
echo ""
echo "  Access instructions:"
echo "    GitLab:    https://${GITLAB_HOSTNAME}  (${CONTOUR_LB_IP})"
echo "    Harbor:    https://${HARBOR_HOSTNAME}  (${CONTOUR_LB_IP})"
echo "    ArgoCD:    https://${ARGOCD_HOSTNAME}  (${CONTOUR_LB_IP})"
if [[ -n "${FRONTEND_LB_IP}" ]]; then
  echo "    Online Boutique:  http://${FRONTEND_LB_IP}  (microservices-demo frontend-external)"
fi
if [[ "${USE_SSLIP_DNS}" == "true" ]] && [[ -n "${BOUTIQUE_HOSTNAME:-}" ]]; then
  echo "    Online Boutique:  https://${BOUTIQUE_HOSTNAME}  (Let's Encrypt TLS)"
fi
if [[ "${USE_SSLIP_DNS}" != "true" ]]; then
echo ""
echo "  DNS / hosts file entries (add to your local machine):"
echo "    ${CONTOUR_LB_IP} ${HARBOR_HOSTNAME} ${GITLAB_HOSTNAME} ${ARGOCD_HOSTNAME}"
fi
echo ""
echo "  Login credentials:"
echo "    GitLab:    root  / ${GITLAB_ROOT_PASSWORD}"
echo "    Harbor:    admin / ${HARBOR_ADMIN_PASSWORD}"
echo "    ArgoCD:    admin / ${ARGOCD_PASSWORD}"
echo ""
echo "  CI/CD Pipeline:"
echo "    GitLab Project:   https://${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}"
echo "    Harbor CI Project: https://${HARBOR_HOSTNAME}/harbor/projects (${HARBOR_CI_PROJECT})"
echo "    ArgoCD Application: https://${ARGOCD_HOSTNAME}/applications/argocd/microservices-demo"
echo ""
echo "  Live Demo Instructions:"
echo "    1. Navigate to https://${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}"
echo "       and open the file 'demo-config.yaml' for editing."
echo "    2. Change the 'banner_text' value to a custom message"
echo "       (e.g., banner_text: \"Welcome to VCF 9\")."
echo "    3. Commit the change — watch the CI pipeline run at:"
echo "       https://${GITLAB_HOSTNAME}/root/${GITLAB_PROJECT_NAME}/-/pipelines"
echo "    4. ArgoCD will automatically sync the new image. Monitor at:"
echo "       https://${ARGOCD_HOSTNAME}/applications/argocd/microservices-demo"
echo "       Then refresh the Online Boutique frontend to see the banner."
echo ""

log_success "Deploy GitOps deployment complete"

exit 0
