#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Knative — Serverless Audit Function Deploy Script
#
# This script installs Knative Serving on an existing VKS cluster and deploys
# a serverless audit function with a Next.js dashboard:
#   Phase 1:  Kubeconfig Setup & Connectivity Check
#   Phase 2:  Knative Serving CRDs
#   Phase 3:  Knative Serving Core
#   Phase 4:  net-contour Networking Plugin
#   Phase 5:  Ingress Configuration
#   Phase 6:  DNS Configuration (sslip.io)
#   Phase 7:  Audit Function Deployment (Knative Service)
#   Phase 8:  Dashboard Deployment (Next.js)
#   Phase 9:  Verification & Scale-to-Zero Demo
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running)
#   - Valid admin kubeconfig file for the target cluster
#   - Container images pushed to the registry
#
# Exit Codes:
#   0 — Success
#   1 — Variable validation failure
#   2 — CRD or core installation failure
#   3 — Networking/ingress failure
#   4 — DNS configuration failure
#   5 — Audit function deployment failure
#   6 — Dashboard deployment failure
#   7 — Verification failure
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-knative/deploy-knative.sh
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

# --- Knative Versions ---
KNATIVE_SERVING_VERSION="${KNATIVE_SERVING_VERSION:-1.21.2}"
NET_CONTOUR_VERSION="${NET_CONTOUR_VERSION:-1.21.1}"

# --- Namespaces ---
KNATIVE_NAMESPACE="${KNATIVE_NAMESPACE:-knative-serving}"
DEMO_NAMESPACE="${DEMO_NAMESPACE:-knative-demo}"

# --- Container Images ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
AUDIT_IMAGE="${AUDIT_IMAGE:-${CONTAINER_REGISTRY}/knative-audit:${IMAGE_TAG}}"

# --- Knative Configuration ---
SCALE_TO_ZERO_GRACE_PERIOD="${SCALE_TO_ZERO_GRACE_PERIOD:-30s}"

# --- Timeouts and Polling ---
KNATIVE_TIMEOUT="${KNATIVE_TIMEOUT:-300}"
POD_TIMEOUT="${POD_TIMEOUT:-300}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

###############################################################################
# Derived Variables (computed — do not edit)
###############################################################################

KNATIVE_CRDS_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-crds.yaml"
KNATIVE_CORE_URL="https://github.com/knative/serving/releases/download/knative-v${KNATIVE_SERVING_VERSION}/serving-core.yaml"
CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/contour.yaml"
NET_CONTOUR_URL="https://github.com/knative-extensions/net-contour/releases/download/knative-v${NET_CONTOUR_VERSION}/net-contour.yaml"
DASHBOARD_IMAGE="${CONTAINER_REGISTRY}/knative-dashboard:${IMAGE_TAG}"

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
    "KNATIVE_SERVING_VERSION"
    "NET_CONTOUR_VERSION"
    "AUDIT_IMAGE"
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

###############################################################################
# Phase 1: Kubeconfig Setup & Connectivity Check
###############################################################################

log_step 1 "Setting up kubeconfig and verifying connectivity"

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

###############################################################################
# Phase 2: Knative Serving CRDs
###############################################################################

log_step 2 "Installing Knative Serving CRDs (v${KNATIVE_SERVING_VERSION})"

if ! kubectl apply -f "${KNATIVE_CRDS_URL}"; then
  log_error "Failed to apply Knative Serving CRDs from ${KNATIVE_CRDS_URL}"
  exit 2
fi

if ! wait_for_condition "Knative CRDs to be Established" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Established crd/services.serving.knative.dev crd/routes.serving.knative.dev crd/configurations.serving.knative.dev crd/revisions.serving.knative.dev --timeout=5s"; then
  log_error "Knative CRDs did not reach Established condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

log_success "Knative Serving CRDs installed and Established"

###############################################################################
# Phase 3: Knative Serving Core
###############################################################################

log_step 3 "Installing Knative Serving Core (v${KNATIVE_SERVING_VERSION})"

# Label knative-serving namespace as privileged before installing core
kubectl label ns "${KNATIVE_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# First apply creates the webhook service and deployments but may fail on the
# Image resource because the validation webhook isn't ready yet. This is
# expected on first install — the second apply succeeds after the webhook starts.
kubectl apply -f "${KNATIVE_CORE_URL}" || true

# Wait for the webhook deployment to be ready before re-applying
if ! wait_for_condition "Knative webhook to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment/webhook -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "Knative webhook did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

# Re-apply to pick up the Image resource that failed on first attempt
if ! kubectl apply -f "${KNATIVE_CORE_URL}"; then
  log_error "Failed to apply Knative Serving Core from ${KNATIVE_CORE_URL}"
  exit 2
fi

# Restart deployments that may be stuck from the partial first apply
kubectl rollout restart deploy -n "${KNATIVE_NAMESPACE}" 2>/dev/null || true

if ! wait_for_condition "Knative Core deployments to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment --all -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "Knative Core deployments did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 2
fi

log_success "Knative Serving Core installed and Available"

# Re-apply CRDs to restore webhook configurations now that the webhook service is running
kubectl apply -f "${KNATIVE_CRDS_URL}" >/dev/null 2>&1 || true

###############################################################################
# Phase 4: net-contour Networking Plugin
###############################################################################

log_step 4 "Installing Contour and net-contour networking plugin (v${NET_CONTOUR_VERSION})"

# Install Contour into contour-external and contour-internal namespaces
if ! kubectl apply -f "${CONTOUR_URL}"; then
  log_error "Failed to apply Contour from ${CONTOUR_URL}"
  exit 3
fi

# Label Contour namespaces as privileged (Envoy/Contour pods need it)
kubectl label ns contour-external pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
kubectl label ns contour-internal pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# Restart Contour/Envoy after labeling (pods may have failed PodSecurity)
kubectl rollout restart deploy contour -n contour-external 2>/dev/null || true
kubectl rollout restart ds envoy -n contour-external 2>/dev/null || true
kubectl rollout restart deploy contour -n contour-internal 2>/dev/null || true
kubectl rollout restart ds envoy -n contour-internal 2>/dev/null || true

# Install net-contour controller (bridges Knative to Contour)
if ! kubectl apply -f "${NET_CONTOUR_URL}"; then
  log_error "Failed to apply net-contour plugin from ${NET_CONTOUR_URL}"
  exit 3
fi

if ! wait_for_condition "net-contour controller to be Available" \
  "${KNATIVE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl wait --for=condition=Available deployment/net-contour-controller -n '${KNATIVE_NAMESPACE}' --timeout=5s"; then
  log_error "net-contour controller did not reach Available condition within ${KNATIVE_TIMEOUT}s"
  exit 3
fi

log_success "Contour and net-contour networking plugin installed and Available"

###############################################################################
# Phase 5: Ingress Configuration
###############################################################################

log_step 5 "Configuring Knative ingress (Contour)"

kubectl patch configmap/config-network \
  --namespace "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p '{"data":{"ingress-class":"contour.ingress.networking.knative.dev","external-domain-tls":"Disabled"}}' || {
  log_error "Failed to patch config-network ConfigMap"
  exit 3
}

log_success "Knative ingress configured to use Contour (external-domain-tls: Disabled)"

###############################################################################
# Phase 6: DNS Configuration (sslip.io)
###############################################################################

log_step 6 "Configuring DNS with sslip.io"

# Wait for the Envoy LoadBalancer (installed by net-contour) to get an external IP
if ! wait_for_condition "Envoy LoadBalancer to get external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get svc -n contour-external envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '.'"; then
  log_error "Envoy LoadBalancer in contour-external did not receive an external IP within ${LB_TIMEOUT}s"
  exit 4
fi

ENVOY_LB_IP=$(kubectl get svc -n contour-external envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Envoy LoadBalancer IP: ${ENVOY_LB_IP}"

# Patch config-domain with sslip.io magic DNS
kubectl patch configmap/config-domain \
  --namespace "${KNATIVE_NAMESPACE}" \
  --type merge \
  -p "{\"data\":{\"${ENVOY_LB_IP}.sslip.io\":\"\"}}" || {
  log_error "Failed to patch config-domain ConfigMap with sslip.io domain"
  exit 4
}

log_success "DNS configured: *.${ENVOY_LB_IP}.sslip.io"

###############################################################################
# Phase 7: Audit Function Deployment (Knative Service)
###############################################################################

log_step 7 "Deploying audit function as Knative Service"

# Create demo namespace if it does not exist
if kubectl get ns "${DEMO_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${DEMO_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${DEMO_NAMESPACE}"
  log_success "Namespace '${DEMO_NAMESPACE}' created"
fi

# Label namespace as privileged to allow Knative pods (queue-proxy sidecar)
kubectl label ns "${DEMO_NAMESPACE}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true

# Apply Knative Service manifest for asset-audit
cat <<EOF | kubectl apply -f -
apiVersion: serving.knative.dev/v1
kind: Service
metadata:
  name: asset-audit
  namespace: ${DEMO_NAMESPACE}
spec:
  template:
    metadata:
      annotations:
        autoscaling.knative.dev/scale-to-zero-grace-period: "${SCALE_TO_ZERO_GRACE_PERIOD}"
    spec:
      containers:
        - image: ${AUDIT_IMAGE}
          ports:
            - containerPort: 8080
EOF

# Wait for Knative Service to be Ready
if ! wait_for_condition "Knative Service 'asset-audit' to be Ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get ksvc asset-audit -n '${DEMO_NAMESPACE}' -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q 'True'"; then
  log_error "Knative Service 'asset-audit' did not reach Ready status within ${POD_TIMEOUT}s"
  exit 5
fi

# Extract the Knative Service URL
AUDIT_FUNCTION_URL=$(kubectl get ksvc asset-audit -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.url}')
log_success "Audit function deployed: ${AUDIT_FUNCTION_URL}"

###############################################################################
# Phase 8: Dashboard Deployment (Next.js)
###############################################################################

log_step 8 "Deploying Knative dashboard"

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: knative-dashboard
  namespace: ${DEMO_NAMESPACE}
  labels:
    app: knative-dashboard
spec:
  replicas: 1
  selector:
    matchLabels:
      app: knative-dashboard
  template:
    metadata:
      labels:
        app: knative-dashboard
    spec:
      containers:
        - name: dashboard
          image: ${DASHBOARD_IMAGE}
          ports:
            - containerPort: 3000
          env:
            - name: API_HOST
              value: "${AUDIT_FUNCTION_URL}"
EOF

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: knative-dashboard
  namespace: ${DEMO_NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: knative-dashboard
  ports:
    - name: http
      port: 80
      targetPort: 3000
      protocol: TCP
EOF

# Wait for dashboard pod to be ready
if ! wait_for_condition "Dashboard pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${DEMO_NAMESPACE}' -l app=knative-dashboard --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Dashboard pod did not reach Running state within ${POD_TIMEOUT}s"
  exit 6
fi

# Wait for dashboard LoadBalancer IP
if ! wait_for_condition "Dashboard LoadBalancer to get external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get svc knative-dashboard -n '${DEMO_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null | grep -q '.'"; then
  log_error "Dashboard LoadBalancer did not receive an external IP within ${LB_TIMEOUT}s"
  exit 6
fi

DASHBOARD_IP=$(kubectl get svc knative-dashboard -n "${DEMO_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "Dashboard deployed: http://${DASHBOARD_IP}"

###############################################################################
# Phase 9: Verification & Scale-to-Zero Demo
###############################################################################

log_step 9 "Verifying audit function and scale-to-zero behavior"

# Send a test HTTP POST to the audit function via kubectl run (container can't
# reach sslip.io URLs directly — must test from inside the cluster)
AUDIT_INTERNAL_URL="http://asset-audit.${DEMO_NAMESPACE}.svc.cluster.local"
AUDIT_RESPONSE=""
VERIFY_ELAPSED=0
while [[ "${VERIFY_ELAPSED}" -lt "${KNATIVE_TIMEOUT}" ]]; do
  AUDIT_RESPONSE=$(kubectl run audit-test-${VERIFY_ELAPSED} --rm -i --restart=Never \
    --image=curlimages/curl:latest -n "${DEMO_NAMESPACE}" -- \
    curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"action\":\"create\",\"asset_name\":\"test-server\",\"asset_id\":\"demo-001\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    "${AUDIT_INTERNAL_URL}" 2>/dev/null) || true
  if [[ "${AUDIT_RESPONSE}" == "200" ]]; then
    break
  fi
  echo "  Waiting for audit function to respond... (${VERIFY_ELAPSED}s/${KNATIVE_TIMEOUT}s elapsed)"
  sleep "${POLL_INTERVAL}"
  VERIFY_ELAPSED=$((VERIFY_ELAPSED + POLL_INTERVAL))
done

if [[ "${AUDIT_RESPONSE}" != "200" ]]; then
  log_error "Audit function did not return HTTP 200 within ${KNATIVE_TIMEOUT}s (last status: ${AUDIT_RESPONSE})"
  exit 7
fi

# Log the full response body
AUDIT_BODY=$(kubectl run audit-body-test --rm -i --restart=Never \
  --image=curlimages/curl:latest -n "${DEMO_NAMESPACE}" -- \
  curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "{\"action\":\"create\",\"asset_name\":\"test-server\",\"asset_id\":\"demo-001\",\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  "${AUDIT_INTERNAL_URL}" 2>/dev/null) || true
echo "  Audit function response: ${AUDIT_BODY}"
log_success "Audit function responded with HTTP 200"

# Wait for scale-to-zero
echo "  Waiting for scale-to-zero (grace period: ${SCALE_TO_ZERO_GRACE_PERIOD})..."
sleep 60

AUDIT_POD_COUNT=$(kubectl get pods -n "${DEMO_NAMESPACE}" -l serving.knative.dev/service=asset-audit --no-headers 2>/dev/null | grep -c "Running" || echo "0")
if [[ "${AUDIT_POD_COUNT}" -eq 0 ]]; then
  log_success "Scale-to-zero confirmed: 0 audit function pods running"
else
  log_warn "Audit function still has ${AUDIT_POD_COUNT} running pod(s) — scale-to-zero may need more time"
fi

log_success "Verification complete"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Knative — Deployment Complete"
echo "============================================="
echo "  Cluster:              ${CLUSTER_NAME}"
echo "  Knative Serving:      v${KNATIVE_SERVING_VERSION}"
echo "  net-contour:          v${NET_CONTOUR_VERSION}"
echo "  Ingress IP:           ${ENVOY_LB_IP}"
echo "  Domain:               ${ENVOY_LB_IP}.sslip.io"
echo "  Audit Function:       ${AUDIT_FUNCTION_URL}"
echo "  Dashboard:            http://${DASHBOARD_IP}"
echo "  Audit Image:          ${AUDIT_IMAGE}"
echo "  Scale-to-Zero Grace:  ${SCALE_TO_ZERO_GRACE_PERIOD}"
echo "============================================="
echo ""

exit 0
