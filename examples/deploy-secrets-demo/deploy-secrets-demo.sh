#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Secrets Demo — Secret Store Integration Deploy Script
#
# This script deploys a secrets demo application on an existing VKS cluster
# provisioned by Deploy Cluster. It demonstrates VCF Secret Store integration
# with vault-injected secrets for Redis and PostgreSQL authentication.
#
#   Phase 1: Create KeyValueSecrets in Supervisor Namespace
#   Phase 2: Create ServiceAccount + Long-Lived Token in Supervisor Namespace
#   Phase 3: Switch to Guest Cluster Kubeconfig
#   Phase 4: Create Namespace, Copy Token, Deploy Vault-Injector
#   Phase 5: Deploy Data Tier (Redis + PostgreSQL)
#   Phase 6: Build + Push Next.js Container Image
#   Phase 7: Deploy Web Dashboard with Vault Annotations
#   Phase 8: Verify LoadBalancer IP and HTTP Connectivity
#
# Prerequisites:
#   - Deploy Cluster completed successfully (VKS cluster running)
#   - Valid admin kubeconfig for the guest cluster
#   - VCF CLI installed and configured with supervisor context
#   - kubectl installed
#   - openssl installed
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-secrets-demo/deploy-secrets-demo.sh
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

# --- VCF CLI Connection ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Redis Credentials ---
REDIS_PASSWORD="${REDIS_PASSWORD:-$(openssl rand -base64 18)}"

# --- PostgreSQL Credentials ---
POSTGRES_USER="${POSTGRES_USER:-secretsadmin}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(openssl rand -base64 18)}"
POSTGRES_DB="${POSTGRES_DB:-secretsdb}"

# --- Secret Store ---
SECRET_STORE_IP="${SECRET_STORE_IP:-}"

# --- Namespace ---
NAMESPACE="${NAMESPACE:-secrets-demo}"

# --- Supervisor Namespace ---
SUPERVISOR_NAMESPACE="${SUPERVISOR_NAMESPACE:-}"

# --- Container Image ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_NAME="${IMAGE_NAME:-secrets-dashboard}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# --- Timeouts and Polling ---
POD_TIMEOUT="${POD_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"

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

validate_variables() {
  local missing=0
  local required_vars=(
    "CLUSTER_NAME"
    "KUBECONFIG_FILE"
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "SECRET_STORE_IP"
    "SUPERVISOR_NAMESPACE"
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
# Phase 1: Create KeyValueSecrets in Supervisor Namespace
###############################################################################

log_step 1 "Creating KeyValueSecrets (redis-creds, postgres-creds) in supervisor namespace"

# --- redis-creds KeyValueSecret ---
if vcf secret list 2>/dev/null | grep -q "redis-creds"; then
  log_success "KeyValueSecret 'redis-creds' already exists, skipping creation"
else
  REDIS_CREDS_FILE=$(mktemp /tmp/redis-creds-XXXXXX.yaml)
  cat > "${REDIS_CREDS_FILE}" <<EOF
apiVersion: secretstore.vmware.com/v1alpha1
kind: KeyValueSecret
metadata:
  name: redis-creds
spec:
  data:
  - key: password
    value: ${REDIS_PASSWORD}
EOF

  if ! vcf secret create -f "${REDIS_CREDS_FILE}"; then
    log_error "Failed to create KeyValueSecret 'redis-creds'"
    rm -f "${REDIS_CREDS_FILE}"
    exit 2
  fi

  rm -f "${REDIS_CREDS_FILE}"
  log_success "KeyValueSecret 'redis-creds' created"
fi

# --- postgres-creds KeyValueSecret ---
if vcf secret list 2>/dev/null | grep -q "postgres-creds"; then
  log_success "KeyValueSecret 'postgres-creds' already exists, skipping creation"
else
  POSTGRES_CREDS_FILE=$(mktemp /tmp/postgres-creds-XXXXXX.yaml)
  cat > "${POSTGRES_CREDS_FILE}" <<EOF
apiVersion: secretstore.vmware.com/v1alpha1
kind: KeyValueSecret
metadata:
  name: postgres-creds
spec:
  data:
  - key: username
    value: ${POSTGRES_USER}
  - key: password
    value: ${POSTGRES_PASSWORD}
  - key: database
    value: ${POSTGRES_DB}
EOF

  if ! vcf secret create -f "${POSTGRES_CREDS_FILE}"; then
    log_error "Failed to create KeyValueSecret 'postgres-creds'"
    rm -f "${POSTGRES_CREDS_FILE}"
    exit 2
  fi

  rm -f "${POSTGRES_CREDS_FILE}"
  log_success "KeyValueSecret 'postgres-creds' created"
fi

log_success "Phase 1 complete — KeyValueSecrets created"

###############################################################################
# Phase 2: Create ServiceAccount + Long-Lived Token in Supervisor Namespace
###############################################################################

log_step 2 "Creating ServiceAccount and long-lived token in supervisor namespace"

# Create ServiceAccount 'internal-app'
if kubectl get serviceaccount internal-app >/dev/null 2>&1; then
  log_success "ServiceAccount 'internal-app' already exists, skipping creation"
else
  if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: internal-app
EOF
  then
    log_error "Failed to create ServiceAccount 'internal-app'"
    exit 3
  fi
  log_success "ServiceAccount 'internal-app' created"
fi

# Create a long-lived token Secret for the ServiceAccount
if kubectl get secret internal-app-token >/dev/null 2>&1; then
  log_success "Secret 'internal-app-token' already exists, skipping creation"
else
  if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: internal-app-token
  annotations:
    kubernetes.io/service-account.name: internal-app
type: kubernetes.io/service-account-token
EOF
  then
    log_error "Failed to create token Secret 'internal-app-token'"
    exit 3
  fi
  log_success "Secret 'internal-app-token' created"
fi

# Wait for the token to be populated by the token controller
if ! wait_for_condition "token to be populated in Secret 'internal-app-token'" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get secret internal-app-token -o jsonpath='{.data.token}' 2>/dev/null) ]]"; then
  log_error "Token was not populated in Secret 'internal-app-token' within ${POD_TIMEOUT}s"
  exit 3
fi

log_success "Phase 2 complete — ServiceAccount 'internal-app' with long-lived token ready"

###############################################################################
# Phase 3: Switch to Guest Cluster Kubeconfig
###############################################################################

log_step 3 "Switching to guest cluster kubeconfig"

if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
  log_error "Guest cluster kubeconfig file not found at '${KUBECONFIG_FILE}'. Ensure Deploy Cluster has completed and the kubeconfig file exists."
  exit 4
fi

export KUBECONFIG="${KUBECONFIG_FILE}"

if ! kubectl get namespaces >/dev/null 2>&1; then
  log_error "Unable to reach guest cluster using kubeconfig at '${KUBECONFIG_FILE}'. Verify the cluster is running and the kubeconfig is valid."
  exit 4
fi

log_success "Phase 3 complete — switched to guest cluster '${CLUSTER_NAME}' via '${KUBECONFIG_FILE}'"

###############################################################################
# Phase 4: Create Namespace, Copy Token, Deploy Vault-Injector
###############################################################################

log_step 4 "Setting up namespace, token, and vault-injector in guest cluster"

# --- Create secrets-demo namespace ---
if kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${NAMESPACE}"
  log_success "Namespace '${NAMESPACE}' created"
fi

kubectl label ns "${NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite >/dev/null 2>&1 || true

# --- Copy service account token from supervisor into guest cluster namespace ---
if kubectl get secret internal-app-token -n "${NAMESPACE}" >/dev/null 2>&1; then
  log_success "Secret 'internal-app-token' already exists in namespace '${NAMESPACE}', skipping copy"
else
  # Retrieve the token from the supervisor context (saved before kubeconfig switch)
  # We need to temporarily switch back to get the token data
  SAVED_KUBECONFIG="${KUBECONFIG}"
  unset KUBECONFIG

  SA_TOKEN=$(kubectl get secret internal-app-token -o jsonpath='{.data.token}')
  SA_CA_CRT=$(kubectl get secret internal-app-token -o jsonpath='{.data.ca\.crt}')

  export KUBECONFIG="${SAVED_KUBECONFIG}"

  if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: internal-app-token
  namespace: ${NAMESPACE}
type: Opaque
data:
  token: ${SA_TOKEN}
  ca.crt: ${SA_CA_CRT}
EOF
  then
    log_error "Failed to copy service account token into namespace '${NAMESPACE}'"
    exit 5
  fi
  log_success "Service account token copied into namespace '${NAMESPACE}'"
fi

# --- Ensure tkg-packages namespace exists (vault-injector installs here) ---
if ! kubectl get ns tkg-packages >/dev/null 2>&1; then
  kubectl create ns tkg-packages
  kubectl label ns tkg-packages pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null 2>&1 || true
  log_success "Namespace 'tkg-packages' created"
fi

# --- Install vault-injector via VKS standard package ---
log_step "4b" "Installing vault-injector package"

if vcf package installed list -n tkg-packages 2>/dev/null | grep -q "vault-injector"; then
  log_success "vault-injector package already installed, skipping"
else
  VAULT_VALUES_FILE=$(mktemp /tmp/vault-injector-values-XXXXXX.yaml)
  cat > "${VAULT_VALUES_FILE}" <<VALEOF
externalIP: "${SECRET_STORE_IP}"
namespace: "tkg-packages"
agentInjectVaultAddr: "http://secret-store-service.tkg-packages.svc.cluster.local:8200"
agentInjectVaultImage: "projects.packages.broadcom.com/vsphere/iaas/secret-store-service/9.0.0/openbao_ssl:0.0.15"
VALEOF

  if ! vcf package install vault-injector \
    -p vault-injector.kubernetes.vmware.com \
    --version 1.6.2+vmware.1-vks.1 \
    --values-file "${VAULT_VALUES_FILE}" \
    -n tkg-packages; then
    log_error "Failed to install vault-injector package"
    rm -f "${VAULT_VALUES_FILE}"
    exit 5
  fi

  rm -f "${VAULT_VALUES_FILE}"
  log_success "vault-injector package installed"
fi

# Wait for vault-injector pod readiness
if ! wait_for_condition "vault-injector pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n 'tkg-packages' -l app.kubernetes.io/name=vault-injector --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Vault-injector pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "tkg-packages" -l app.kubernetes.io/name=vault-injector -o wide 2>/dev/null || true
  exit 5
fi

log_success "Phase 4 complete — vault-injector deployed and running in namespace '${NAMESPACE}'"

###############################################################################
# Phase 5: Deploy Data Tier (Redis + PostgreSQL)
###############################################################################

log_step 5 "Deploying Redis and PostgreSQL data tier"

# --- Redis Deployment + Service ---
if ! cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
      - name: redis
        image: redis:7-alpine
        command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: redis
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
EOF
then
  log_error "Failed to deploy Redis"
  exit 6
fi

log_success "Redis Deployment and ClusterIP Service applied"

# --- PostgreSQL Deployment + Service ---
if ! cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        env:
        - name: POSTGRES_USER
          value: "${POSTGRES_USER}"
        - name: POSTGRES_PASSWORD
          value: "${POSTGRES_PASSWORD}"
        - name: POSTGRES_DB
          value: "${POSTGRES_DB}"
        ports:
        - containerPort: 5432
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${NAMESPACE}
spec:
  type: ClusterIP
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
    protocol: TCP
EOF
then
  log_error "Failed to deploy PostgreSQL"
  exit 6
fi

log_success "PostgreSQL Deployment and ClusterIP Service applied"

# Wait for Redis pod readiness
if ! wait_for_condition "Redis pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${NAMESPACE}' -l app=redis --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Redis pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${NAMESPACE}" -l app=redis -o wide 2>/dev/null || true
  exit 6
fi

log_success "Redis pod is running"

# Wait for PostgreSQL pod readiness
if ! wait_for_condition "PostgreSQL pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${NAMESPACE}' -l app=postgres --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "PostgreSQL pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${NAMESPACE}" -l app=postgres -o wide 2>/dev/null || true
  exit 6
fi

log_success "PostgreSQL pod is running"

log_success "Phase 5 complete — Redis and PostgreSQL deployed and running"

###############################################################################
# Phase 6: Build + Push Next.js Container Image
###############################################################################

log_step 6 "Building and pushing Next.js container image"

FULL_IMAGE="${CONTAINER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"

if ! docker build -t "${FULL_IMAGE}" examples/deploy-secrets-demo/dashboard/; then
  log_error "Failed to build container image '${FULL_IMAGE}'"
  exit 7
fi

log_success "Container image '${FULL_IMAGE}' built successfully"

if ! docker push "${FULL_IMAGE}"; then
  log_error "Failed to push container image '${FULL_IMAGE}'"
  exit 7
fi

log_success "Phase 6 complete — container image '${FULL_IMAGE}' pushed"

###############################################################################
# Phase 7: Deploy Web Dashboard with Vault Annotations
###############################################################################

log_step 7 "Deploying web dashboard with vault-injected secrets"

# --- Create ServiceAccount for the dashboard pod ---
if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-service-account
  namespace: ${NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: test-service-account-token
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: test-service-account
type: kubernetes.io/service-account-token
EOF
then
  log_error "Failed to create test-service-account resources"
  exit 8
fi

log_success "ServiceAccount 'test-service-account' and token created"

# --- Deploy secrets-dashboard Deployment with vault annotations ---
if ! cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secrets-dashboard
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secrets-dashboard
  template:
    metadata:
      labels:
        app: secrets-dashboard
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "${SUPERVISOR_NAMESPACE}"
        vault.hashicorp.com/agent-inject-secret-redis-creds: "secret/data/${SUPERVISOR_NAMESPACE}/redis-creds"
        vault.hashicorp.com/agent-inject-secret-postgres-creds: "secret/data/${SUPERVISOR_NAMESPACE}/postgres-creds"
        vault.hashicorp.com/tls-skip-verify: "true"
    spec:
      serviceAccountName: test-service-account
      containers:
      - name: dashboard
        image: ${CONTAINER_REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
        ports:
        - containerPort: 3000
        env:
        - name: REDIS_HOST
          value: "redis.${NAMESPACE}.svc.cluster.local"
        - name: POSTGRES_HOST
          value: "postgres.${NAMESPACE}.svc.cluster.local"
        volumeMounts:
        - mountPath: /var/run/secrets/kubernetes.io/serviceaccount
          name: vault-token
      volumes:
      - name: vault-token
        secret:
          secretName: internal-app-token
---
apiVersion: v1
kind: Service
metadata:
  name: secrets-dashboard-lb
  namespace: ${NAMESPACE}
spec:
  type: LoadBalancer
  selector:
    app: secrets-dashboard
  ports:
  - port: 80
    targetPort: 3000
    protocol: TCP
EOF
then
  log_error "Failed to deploy web dashboard"
  exit 8
fi

log_success "Dashboard Deployment and LoadBalancer Service applied"

# Wait for dashboard pod readiness
if ! wait_for_condition "dashboard pod to be ready" \
  "${POD_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get pods -n '${NAMESPACE}' -l app=secrets-dashboard --no-headers 2>/dev/null | grep -q 'Running'"; then
  log_error "Dashboard pod did not reach Running state within ${POD_TIMEOUT}s"
  kubectl get pods -n "${NAMESPACE}" -l app=secrets-dashboard -o wide 2>/dev/null || true
  exit 8
fi

log_success "Phase 7 complete — web dashboard deployed with vault annotations"

###############################################################################
# Phase 8: Verify LoadBalancer IP and HTTP Connectivity
###############################################################################

log_step 8 "Waiting for LoadBalancer IP and verifying HTTP connectivity"

# Wait for LoadBalancer external IP to be assigned
if ! wait_for_condition "LoadBalancer 'secrets-dashboard-lb' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get svc secrets-dashboard-lb -n '${NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer 'secrets-dashboard-lb' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get svc secrets-dashboard-lb -n "${NAMESPACE}" -o wide 2>/dev/null || true
  exit 9
fi

DASHBOARD_IP=$(kubectl get svc secrets-dashboard-lb -n "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "LoadBalancer 'secrets-dashboard-lb' assigned external IP: ${DASHBOARD_IP}"

# HTTP connectivity test
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${DASHBOARD_IP}" --max-time 10 || true)
if [[ "${HTTP_STATUS}" == "200" ]]; then
  log_success "HTTP connectivity test passed — received status 200 from http://${DASHBOARD_IP}"
else
  log_error "HTTP test returned status ${HTTP_STATUS} from http://${DASHBOARD_IP} (expected 200)"
  exit 9
fi

log_success "Phase 8 complete — dashboard is accessible"

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Secrets Demo — Deployment Complete"
echo "============================================="
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Namespace:  ${NAMESPACE}"
echo "  Kubeconfig: ${KUBECONFIG_FILE}"
echo ""
echo "  Deployed Services:"
echo "    - Redis:      redis.${NAMESPACE}.svc.cluster.local:6379"
echo "    - PostgreSQL: postgres.${NAMESPACE}.svc.cluster.local:5432"
echo "    - Vault Injector: vault-agent-injector-svc.${NAMESPACE}.svc.cluster.local:443"
echo "    - Dashboard:  http://${DASHBOARD_IP}"
echo "============================================="
echo ""

exit 0
