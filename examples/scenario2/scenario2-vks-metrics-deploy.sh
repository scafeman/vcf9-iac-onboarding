#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Scenario 2 — VKS Metrics Observability Deploy Script
#
# This script installs the metrics observability stack on an existing VKS
# cluster provisioned by Scenario 1:
#   Phase 1:  Kubeconfig Setup & Connectivity Check
#   Phase 2:  Node Sizing Advisory
#   Phase 3:  Package Namespace Creation
#   Phase 4:  TKG Package Repository Registration
#   Phase 5:  Telegraf Installation (metrics collection)
#   Phase 6:  cert-manager Installation (Prometheus prerequisite)
#   Phase 7:  Contour Installation (Prometheus prerequisite)
#   Phase 8:  Prometheus Installation (metrics storage & querying)
#   Phase 9:  Grafana Operator Installation (dashboards)
#   Phase 10: Grafana Instance, Datasource & Dashboards
#   Phase 11: Verification
#
# Prerequisites:
#   - Scenario 1 completed successfully (VKS cluster running)
#   - Valid admin kubeconfig file for the target cluster
#   - Helm v3 installed (included in the vcf9-dev container Dockerfile)
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/scenario2/scenario2-vks-metrics-deploy.sh
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

# --- Package Repository ---
PACKAGE_NAMESPACE="${PACKAGE_NAMESPACE:-tkg-packages}"
PACKAGE_REPO_NAME="${PACKAGE_REPO_NAME:-tkg-packages}"
PACKAGE_REPO_URL="${PACKAGE_REPO_URL:-projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211}"

# --- Package Versions ---
TELEGRAF_VERSION="${TELEGRAF_VERSION:-}"

# --- Configuration ---
TELEGRAF_VALUES_FILE="${TELEGRAF_VALUES_FILE:-examples/scenario2/telegraf-values.yaml}"
PROMETHEUS_VALUES_FILE="${PROMETHEUS_VALUES_FILE:-examples/scenario2/prometheus-values.yaml}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs}"
NODE_CPU_THRESHOLD="${NODE_CPU_THRESHOLD:-4000}"

# --- Grafana ---
GRAFANA_NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
GRAFANA_INSTANCE_FILE="${GRAFANA_INSTANCE_FILE:-examples/scenario2/grafana-instance.yaml}"
GRAFANA_DATASOURCE_FILE="${GRAFANA_DATASOURCE_FILE:-examples/scenario2/grafana-datasource-prometheus.yaml}"
GRAFANA_DASHBOARDS_FILE="${GRAFANA_DASHBOARDS_FILE:-examples/scenario2/grafana-dashboards-k8s.yaml}"

# --- Timeouts and Polling ---
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-600}"
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
    "TELEGRAF_VERSION"
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

  if ! command -v vcf &>/dev/null; then
    log_error "vcf CLI is not installed or not in PATH"
    missing=1
  fi

  if ! command -v helm &>/dev/null; then
    log_error "helm is not installed or not in PATH (required for Grafana Operator)"
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
  log_error "Kubeconfig file not found at '${KUBECONFIG_FILE}'. Ensure Scenario 1 has completed and the kubeconfig file exists."
  exit 2
fi

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_error "Unable to reach cluster '${CLUSTER_NAME}' using kubeconfig at '${KUBECONFIG_FILE}'. Verify the cluster is running and the kubeconfig is valid."
  exit 2
fi

log_success "Kubeconfig set and cluster '${CLUSTER_NAME}' is reachable"

###############################################################################
# Phase 2: Node Sizing Advisory
###############################################################################

log_step 2 "Checking node resources"

TOTAL_CPU=$(kubectl get nodes -o jsonpath='{.items[*].status.allocatable.cpu}' 2>/dev/null | tr ' ' '\n' | awk '{
  val = $1
  if (val ~ /m$/) {
    gsub(/m$/, "", val)
    sum += val
  } else {
    sum += val * 1000
  }
} END { print int(sum) }')

if [[ -n "${TOTAL_CPU}" ]] && [[ "${TOTAL_CPU}" -lt "${NODE_CPU_THRESHOLD}" ]]; then
  log_warn "Total allocatable CPU (${TOTAL_CPU}m) is below the recommended threshold (${NODE_CPU_THRESHOLD}m)"
  log_warn "Consider scaling worker nodes to 'best-effort-large' VM class to avoid pod scheduling failures"
fi

log_success "Node resource check complete (total allocatable CPU: ${TOTAL_CPU:-unknown}m)"

###############################################################################
# Phase 3: Package Namespace Creation
###############################################################################

log_step 3 "Creating package namespace"

if kubectl get ns "${PACKAGE_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${PACKAGE_NAMESPACE}' already exists, skipping creation"
else
  if ! kubectl create ns "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to create namespace '${PACKAGE_NAMESPACE}'"
    exit 3
  fi
  log_success "Namespace '${PACKAGE_NAMESPACE}' created"
fi

# Telegraf and other packages require host-level access that violates the
# "restricted" PodSecurity standard enforced by default.  Label the namespace
# with the "privileged" standard so package pods can be scheduled.
kubectl label ns "${PACKAGE_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/warn=privileged \
  --overwrite >/dev/null 2>&1 || true

log_success "Namespace '${PACKAGE_NAMESPACE}' labelled with privileged PodSecurity standard"

###############################################################################
# Phase 4: TKG Package Repository Registration
###############################################################################

log_step 4 "Registering package repository"

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

###############################################################################
# Phase 5: Telegraf Installation
###############################################################################

log_step 5 "Installing Telegraf"

if ! vcf package install telegraf \
  -p telegraf.kubernetes.vmware.com \
  -v "${TELEGRAF_VERSION}" \
  --values-file "${TELEGRAF_VALUES_FILE}" \
  -n "${PACKAGE_NAMESPACE}"; then
  log_error "Failed to install Telegraf package"
  exit 5
fi

if ! wait_for_condition "Telegraf package to reconcile" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'telegraf' | grep -qi 'reconcile'"; then
  log_error "Telegraf package did not reconcile within ${PACKAGE_TIMEOUT}s"
  exit 5
fi

log_success "Telegraf installed and reconciled"

###############################################################################
# Phase 6: cert-manager Installation
###############################################################################

log_step 6 "Installing cert-manager"

if ! vcf package install cert-manager \
  -p cert-manager.kubernetes.vmware.com \
  -n "${PACKAGE_NAMESPACE}"; then
  log_error "Failed to install cert-manager package"
  exit 6
fi

if ! wait_for_condition "cert-manager package to reconcile" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'cert-manager' | grep -qi 'reconcile'"; then
  log_error "cert-manager package did not reconcile within ${PACKAGE_TIMEOUT}s"
  exit 6
fi

log_success "cert-manager installed and reconciled"

###############################################################################
# Phase 7: Contour Installation
###############################################################################

log_step 7 "Installing Contour"

if ! vcf package install contour \
  -p contour.kubernetes.vmware.com \
  -n "${PACKAGE_NAMESPACE}"; then
  log_error "Failed to install Contour package"
  exit 7
fi

if ! wait_for_condition "Contour package to reconcile" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'contour' | grep -qi 'reconcile'"; then
  log_error "Contour package did not reconcile within ${PACKAGE_TIMEOUT}s"
  exit 7
fi

log_success "Contour installed and reconciled"

###############################################################################
# Phase 8: Prometheus Installation
###############################################################################

log_step 8 "Installing Prometheus"

if ! vcf package install prometheus \
  -p prometheus.kubernetes.vmware.com \
  --values-file "${PROMETHEUS_VALUES_FILE}" \
  -n "${PACKAGE_NAMESPACE}"; then
  log_error "Failed to install Prometheus package"
  exit 8
fi

if ! wait_for_condition "Prometheus package to reconcile" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'prometheus' | grep -qi 'reconcile'"; then
  log_error "Prometheus package did not reconcile within ${PACKAGE_TIMEOUT}s"
  exit 8
fi

log_success "Prometheus installed and reconciled"

###############################################################################
# Phase 9: Grafana Operator Installation
###############################################################################

log_step 9 "Installing Grafana Operator"

# Create the Grafana namespace if it does not exist
if kubectl get ns "${GRAFANA_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${GRAFANA_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${GRAFANA_NAMESPACE}"
  log_success "Namespace '${GRAFANA_NAMESPACE}' created"
fi

kubectl label ns "${GRAFANA_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=baseline \
  --overwrite >/dev/null 2>&1 || true

# Ensure the Helm repo is available, then install the Grafana Operator
helm repo add grafana-operator https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update 2>/dev/null || true

if ! helm upgrade --install grafana-operator grafana-operator/grafana-operator \
  --namespace "${GRAFANA_NAMESPACE}" --create-namespace; then
  log_error "Failed to install Grafana Operator via Helm"
  exit 9
fi

if ! wait_for_condition "Grafana Operator pod to be ready" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${GRAFANA_NAMESPACE}' -l app.kubernetes.io/name=grafana-operator --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Grafana Operator pod did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 9
fi

log_success "Grafana Operator installed and running"

###############################################################################
# Phase 10: Grafana Instance, Datasource & Dashboards
###############################################################################

log_step 10 "Configuring Grafana instance, datasource and dashboards"

kubectl apply -f "${GRAFANA_INSTANCE_FILE}" || { log_error "Failed to apply Grafana instance manifest"; exit 10; }

if ! wait_for_condition "Grafana pod to be ready" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${GRAFANA_NAMESPACE}' -l app=grafana --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Grafana pod did not reach Running state within ${PACKAGE_TIMEOUT}s"
  exit 10
fi

kubectl apply -f "${GRAFANA_DATASOURCE_FILE}" || { log_error "Failed to apply Grafana datasource manifest"; exit 10; }
kubectl apply -f "${GRAFANA_DASHBOARDS_FILE}" || { log_error "Failed to apply Grafana dashboards manifest"; exit 10; }

log_success "Grafana instance, Prometheus datasource and K8s dashboards configured"

###############################################################################
# Phase 11: Verification
###############################################################################

log_step 11 "Verifying installation"

echo ""
echo "--- Installed Packages ---"
vcf package installed list -n "${PACKAGE_NAMESPACE}"
echo ""

# Check Telegraf pods
echo "--- Telegraf Pods ---"
kubectl get pods -n "${PACKAGE_NAMESPACE}" -l app=telegraf 2>/dev/null || true
TELEGRAF_NOT_RUNNING=$(kubectl get pods -n "${PACKAGE_NAMESPACE}" -l app=telegraf --no-headers 2>/dev/null | grep -v "Running" || true)
if [[ -n "${TELEGRAF_NOT_RUNNING}" ]]; then
  log_warn "Some Telegraf pods are not in Running state:"
  echo "${TELEGRAF_NOT_RUNNING}"
fi

# Check Prometheus pods
echo ""
echo "--- Prometheus Pods ---"
kubectl get pods -n "${PACKAGE_NAMESPACE}" -l app=prometheus 2>/dev/null || true
PROMETHEUS_NOT_RUNNING=$(kubectl get pods -n "${PACKAGE_NAMESPACE}" -l app=prometheus --no-headers 2>/dev/null | grep -v "Running" || true)
if [[ -n "${PROMETHEUS_NOT_RUNNING}" ]]; then
  log_warn "Some Prometheus pods are not in Running state:"
  echo "${PROMETHEUS_NOT_RUNNING}"
fi

# Check Grafana pods
echo ""
echo "--- Grafana Pods ---"
kubectl get pods -n "${GRAFANA_NAMESPACE}" 2>/dev/null || true
GRAFANA_NOT_RUNNING=$(kubectl get pods -n "${GRAFANA_NAMESPACE}" --no-headers 2>/dev/null | grep -v "Running" || true)
if [[ -n "${GRAFANA_NOT_RUNNING}" ]]; then
  log_warn "Some Grafana pods are not in Running state:"
  echo "${GRAFANA_NOT_RUNNING}"
fi

log_success "Verification complete"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Scenario 2 — Deployment Complete"
echo "============================================="
echo "  Cluster:      ${CLUSTER_NAME}"
echo "  Namespace:    ${PACKAGE_NAMESPACE}"
echo "  Telegraf:     ${TELEGRAF_VERSION}"
echo "  cert-manager: (latest from repo)"
echo "  Contour:      (latest from repo)"
echo "  Prometheus:   (latest from repo)"
echo "  Grafana:      Operator + dashboards (ns: ${GRAFANA_NAMESPACE})"
echo "============================================="
echo ""
echo "To access Grafana, run on your workstation:"
echo "  kubectl --kubeconfig=<KUBECONFIG_FILE> port-forward -n ${GRAFANA_NAMESPACE} svc/grafana-service 3000:3000"
echo "Then open http://localhost:3000 in your browser."
echo ""

exit 0
