#!/bin/bash
set -euo pipefail

###############################################################################
# VCF 9 Deploy Cluster — Full Stack Deploy Script
#
# This script automates the complete VCF 9 provisioning workflow end to end:
#   Phase 1: VCF CLI Context Creation
#   Phase 2: Project + RBAC + Supervisor Namespace Provisioning
#   Phase 3: Context Bridge Execution
#   Phase 4: VKS Cluster Deployment
#   Phase 5: Kubeconfig Retrieval via VksCredentialRequest
#   Phase 5g: cert-manager Installation
#   Phase 5h: Contour Installation + envoy-lb Service
#   Phase 5i: Let's Encrypt ClusterIssuer Creation
#   Step 5j: Deploy Node DNS Patcher DaemonSet (sslip.io node-level resolution)
#   Phase 6: Functional Validation Workload Deployment (with sslip.io + TLS)
#
# Edit the variable block below with your environment-specific values,
# then run: bash examples/deploy-cluster/deploy-cluster.sh
###############################################################################

###############################################################################
# Variable Block — Customer-Configurable Values
#
# Fill in the required variables below. Variables with defaults can be
# overridden by setting them in your environment before running the script.
###############################################################################

# --- API Token ---
VCF_API_TOKEN="${VCF_API_TOKEN:-}"

# --- VCFA Connection ---
VCFA_ENDPOINT="${VCFA_ENDPOINT:-}"
TENANT_NAME="${TENANT_NAME:-}"
CONTEXT_NAME="${CONTEXT_NAME:-}"

# --- Project & Namespace ---
PROJECT_NAME="${PROJECT_NAME:-}"
PROJECT_DESCRIPTION="${PROJECT_DESCRIPTION:-Deploy Cluster project}"
USER_IDENTITY="${USER_IDENTITY:-}"
NAMESPACE_PREFIX="${NAMESPACE_PREFIX:-}"
NAMESPACE_DESCRIPTION="${NAMESPACE_DESCRIPTION:-Deploy Cluster namespace}"

# --- Pre-Existing Resources (Region, Zone, Networking) ---
REGION_NAME="${REGION_NAME:-region-us1-a}"
ZONE_NAME="${ZONE_NAME:-}"
VPC_NAME="${VPC_NAME:-region-us1-a-default-vpc}"
TRANSIT_GATEWAY_NAME="${TRANSIT_GATEWAY_NAME:-default@region-us1-a}"
CONNECTIVITY_PROFILE_NAME="${CONNECTIVITY_PROFILE_NAME:-default@region-us1-a}"

# --- Namespace Resource Limits ---
RESOURCE_CLASS="${RESOURCE_CLASS:-xxlarge}"
CPU_LIMIT="${CPU_LIMIT:-100000M}"
MEMORY_LIMIT="${MEMORY_LIMIT:-102400Mi}"

# --- VKS Cluster Configuration ---
CLUSTER_NAME="${CLUSTER_NAME:-}"
K8S_VERSION="${K8S_VERSION:-v1.33.6+vmware.1-fips}"
CONTENT_LIBRARY_ID="${CONTENT_LIBRARY_ID:-}"
SERVICES_CIDR="${SERVICES_CIDR:-10.96.0.0/12}"
PODS_CIDR="${PODS_CIDR:-192.168.156.0/20}"
VM_CLASS="${VM_CLASS:-best-effort-large}"
STORAGE_CLASS="${STORAGE_CLASS:-nfs}"
MIN_NODES="${MIN_NODES:-2}"
MAX_NODES="${MAX_NODES:-10}"
NODE_DISK_SIZE="${NODE_DISK_SIZE:-50Gi}"
CONTROL_PLANE_REPLICAS="${CONTROL_PLANE_REPLICAS:-1}"
NODE_POOL_NAME="${NODE_POOL_NAME:-node-pool-01}"

# --- Container Image ---
CONTAINER_REGISTRY="${CONTAINER_REGISTRY:-scafeman}"
IMAGE_TAG="${IMAGE_TAG:-latest}"

# --- Autoscaler Tuning ---
AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME="${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME:-5m}"
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD="${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD:-5m}"
AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD="${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD:-0.5}"
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE="${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE:-10s}"

# --- OS Image ---
OS_NAME="${OS_NAME:-photon}"
OS_VERSION="${OS_VERSION:-}"

# --- Package Configuration (for Cluster Autoscaler) ---
PACKAGE_NAMESPACE="${PACKAGE_NAMESPACE:-tkg-packages}"
PACKAGE_REPO_NAME="${PACKAGE_REPO_NAME:-tkg-packages}"
PACKAGE_REPO_URL="${PACKAGE_REPO_URL:-projects.packages.broadcom.com/vsphere/supervisor/vks-standard-packages/3.6.0-20260211/vks-standard-packages:3.6.0-20260211}"
PACKAGE_TIMEOUT="${PACKAGE_TIMEOUT:-600}"

# --- Timeouts and Polling ---
CLUSTER_TIMEOUT="${CLUSTER_TIMEOUT:-1800}"
WORKER_TIMEOUT="${WORKER_TIMEOUT:-600}"
KUBECONFIG_TIMEOUT="${KUBECONFIG_TIMEOUT:-300}"
PVC_TIMEOUT="${PVC_TIMEOUT:-300}"
LB_TIMEOUT="${LB_TIMEOUT:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-15}"

# --- sslip.io & Let's Encrypt ---
USE_SSLIP_DNS="${USE_SSLIP_DNS:-true}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
CLUSTER_ISSUER_NAME="${CLUSTER_ISSUER_NAME:-letsencrypt-prod}"
SSLIP_HOSTNAME_PREFIX="${SSLIP_HOSTNAME_PREFIX:-vks-test}"
CERT_WAIT_TIMEOUT="${CERT_WAIT_TIMEOUT:-300}"
CONTOUR_INGRESS_NAMESPACE="${CONTOUR_INGRESS_NAMESPACE:-tanzu-system-ingress}"

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

validate_variables() {
  local missing=0
  local required_vars=(
    "VCF_API_TOKEN"
    "VCFA_ENDPOINT"
    "TENANT_NAME"
    "CONTEXT_NAME"
    "PROJECT_NAME"
    "USER_IDENTITY"
    "NAMESPACE_PREFIX"
    "ZONE_NAME"
    "CLUSTER_NAME"
    "CONTENT_LIBRARY_ID"
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
# Phase 1: VCF CLI Context Creation
###############################################################################

log_step 1 "Creating VCF CLI context and activating it"

# Remove any stale context so create always succeeds (idempotent)
vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true

if ! vcf context create "${CONTEXT_NAME}" \
  --endpoint "https://${VCFA_ENDPOINT}" \
  --type cci \
  --tenant-name "${TENANT_NAME}" \
  --api-token "${VCF_API_TOKEN}" \
  --set-current; then
  log_error "Failed to create VCF CLI context '${CONTEXT_NAME}' for endpoint '${VCFA_ENDPOINT}'. Verify your endpoint URL, tenant name, and API token."
  exit 2
fi

log_success "VCF CLI context '${CONTEXT_NAME}' created and activated"

###############################################################################
# Phase 2: Project + RBAC + Supervisor Namespace Provisioning
###############################################################################

log_step 2 "Creating Project, ProjectRoleBinding, and Supervisor Namespace"

# Idempotency check — skip creation if project already exists
if kubectl get project "${PROJECT_NAME}" 2>/dev/null; then
  log_success "Project '${PROJECT_NAME}' already exists, skipping creation"
else
  # Generate and apply the multi-document manifest
  if ! cat <<EOF | kubectl create --validate=false -f -
apiVersion: project.cci.vmware.com/v1alpha2
kind: Project
metadata:
  name: ${PROJECT_NAME}
spec:
  description: "${PROJECT_DESCRIPTION}"
---
apiVersion: authorization.cci.vmware.com/v1alpha1
kind: ProjectRoleBinding
metadata:
  name: "cci:user:${USER_IDENTITY}"
  namespace: ${PROJECT_NAME}
roleRef:
  apiGroup: authorization.cci.vmware.com
  kind: ProjectRole
  name: admin
subjects:
- kind: User
  name: ${USER_IDENTITY}
---
apiVersion: infrastructure.cci.vmware.com/v1alpha2
kind: SupervisorNamespace
metadata:
  generateName: ${NAMESPACE_PREFIX}
  namespace: ${PROJECT_NAME}
spec:
  description: "${NAMESPACE_DESCRIPTION}"
  regionName: "${REGION_NAME}"
  className: "${RESOURCE_CLASS}"
  vpcName: "${VPC_NAME}"
  initialClassConfigOverrides:
    zones:
    - name: "${ZONE_NAME}"
      cpuLimit: "${CPU_LIMIT}"
      cpuReservation: "0M"
      memoryLimit: "${MEMORY_LIMIT}"
      memoryReservation: "0Mi"
EOF
  then
    log_error "Failed to create Project, RBAC, and Supervisor Namespace resources"
    exit 3
  fi
fi

# Retrieve the dynamic namespace name (works for both new and existing projects)
DYNAMIC_NS_NAME=$(kubectl get supervisornamespaces -n "${PROJECT_NAME}" -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${DYNAMIC_NS_NAME}" ]]; then
  log_error "Failed to retrieve dynamic namespace name from project '${PROJECT_NAME}'"
  exit 3
fi

log_success "Project '${PROJECT_NAME}' provisioned with namespace '${DYNAMIC_NS_NAME}'"

###############################################################################
# Phase 2b + 3: Context Refresh & Bridge (with retry)
#
# The VCFA API may take a few seconds to propagate the new namespace.
# We retry the delete/create/use cycle until the namespace context appears.
###############################################################################

log_step "2b" "Refreshing VCF CLI context and bridging to namespace '${DYNAMIC_NS_NAME}'"

NS_CONTEXT="${CONTEXT_NAME}:${DYNAMIC_NS_NAME}:${PROJECT_NAME}"
BRIDGE_TIMEOUT=120
BRIDGE_INTERVAL=10
BRIDGE_ELAPSED=0
BRIDGE_OK=false

while [[ "${BRIDGE_ELAPSED}" -lt "${BRIDGE_TIMEOUT}" ]]; do
  vcf context delete "${CONTEXT_NAME}" --yes 2>/dev/null || true

  vcf context create "${CONTEXT_NAME}" \
    --endpoint "https://${VCFA_ENDPOINT}" \
    --type cci \
    --tenant-name "${TENANT_NAME}" \
    --api-token "${VCF_API_TOKEN}" \
    --set-current >/dev/null 2>&1 || true

  if vcf context use "${NS_CONTEXT}" 2>/dev/null; then
    # Give the context a moment to initialize
    sleep 5
    if kubectl get clusters 2>/dev/null; then
      BRIDGE_OK=true
      break
    fi
  fi

  echo "  Namespace context not yet available, retrying... (${BRIDGE_ELAPSED}s/${BRIDGE_TIMEOUT}s)"
  sleep "${BRIDGE_INTERVAL}"
  BRIDGE_ELAPSED=$((BRIDGE_ELAPSED + BRIDGE_INTERVAL))
done

if [[ "${BRIDGE_OK}" != "true" ]]; then
  log_error "Namespace context '${NS_CONTEXT}' did not become available within ${BRIDGE_TIMEOUT}s"
  exit 4
fi

log_success "Context bridge complete — now targeting namespace '${DYNAMIC_NS_NAME}' in project '${PROJECT_NAME}'"

###############################################################################
# Phase 4: VKS Cluster Deployment
###############################################################################

log_step 4 "Deploying VKS cluster '${CLUSTER_NAME}' in namespace '${DYNAMIC_NS_NAME}'"

# Idempotency check — skip creation if cluster already exists
if kubectl get cluster "${CLUSTER_NAME}" -n "${DYNAMIC_NS_NAME}" 2>/dev/null; then
  log_success "Cluster '${CLUSTER_NAME}' already exists in namespace '${DYNAMIC_NS_NAME}', skipping creation"
else
  # Generate and apply the Cluster manifest
  # Build the OS image annotation — include os-version only if set (required for ubuntu)
  OS_IMAGE_ANNOTATION="os-name=${OS_NAME}, content-library=${CONTENT_LIBRARY_ID}"
  if [[ -n "${OS_VERSION}" ]]; then
    OS_IMAGE_ANNOTATION="${OS_IMAGE_ANNOTATION}, os-version=${OS_VERSION}"
  fi
  log_success "OS image annotation: ${OS_IMAGE_ANNOTATION}"

  if ! cat <<EOF | kubectl apply --validate=false --insecure-skip-tls-verify -f -
apiVersion: cluster.x-k8s.io/v1beta1
kind: Cluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${DYNAMIC_NS_NAME}
spec:
  clusterNetwork:
    services:
      cidrBlocks:
      - "${SERVICES_CIDR}"
    pods:
      cidrBlocks:
      - "${PODS_CIDR}"
    serviceDomain: cluster.local
  topology:
    class: builtin-generic-v3.4.0
    classNamespace: vmware-system-vks-public
    version: ${K8S_VERSION}
    controlPlane:
      metadata:
        annotations:
          run.tanzu.vmware.com/resolve-os-image: "${OS_IMAGE_ANNOTATION}"
      replicas: ${CONTROL_PLANE_REPLICAS}
    workers:
      machineDeployments:
      - class: node-pool
        name: ${NODE_POOL_NAME}
        metadata:
          annotations:
            run.tanzu.vmware.com/resolve-os-image: "${OS_IMAGE_ANNOTATION}"
            cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "${MAX_NODES}"
            cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "${MIN_NODES}"
    variables:
    - name: vmClass
      value: ${VM_CLASS}
    - name: storageClass
      value: ${STORAGE_CLASS}
    - name: volumes
      value:
      - name: containerd-data
        capacity: ${NODE_DISK_SIZE}
        mountPath: /var/lib/containerd
        storageClass: ${STORAGE_CLASS}
EOF
  then
    log_error "Failed to apply VKS cluster manifest for '${CLUSTER_NAME}'"
    exit 5
  fi
fi

# Wait for cluster to reach Provisioned state
if ! wait_for_condition "cluster '${CLUSTER_NAME}' to reach Provisioned state" \
  "${CLUSTER_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ \$(kubectl get cluster '${CLUSTER_NAME}' -n '${DYNAMIC_NS_NAME}' -o jsonpath='{.status.phase}') == 'Provisioned' ]]"; then
  log_error "Cluster '${CLUSTER_NAME}' did not reach Provisioned state within ${CLUSTER_TIMEOUT}s"
  echo "Current cluster status:"
  kubectl get cluster "${CLUSTER_NAME}" -n "${DYNAMIC_NS_NAME}" -o wide 2>/dev/null || true
  exit 6
fi

log_success "VKS cluster '${CLUSTER_NAME}' is Provisioned and ready"

###############################################################################
# Phase 5: Kubeconfig Retrieval via VCF CLI
###############################################################################

log_step 5 "Retrieving admin kubeconfig for VKS cluster '${CLUSTER_NAME}'"

# Re-activate the namespace-scoped context and ensure the 'cluster' plugin is
# available.  The bridge in Step 2b may have installed plugins, but the long
# cluster-provisioning wait in Step 4 can cause the CLI session state to go
# stale.  Explicitly switching and waiting here guarantees the 'vcf cluster'
# command is present before we call it.
vcf context use "${NS_CONTEXT}" >/dev/null 2>&1 || true

PLUGIN_WAIT=0
PLUGIN_MAX=120
while [[ "${PLUGIN_WAIT}" -lt "${PLUGIN_MAX}" ]]; do
  if vcf cluster --help >/dev/null 2>&1; then
    break
  fi
  echo "  Waiting for VCF CLI 'cluster' plugin to become available... (${PLUGIN_WAIT}s/${PLUGIN_MAX}s)"
  sleep 5
  PLUGIN_WAIT=$((PLUGIN_WAIT + 5))
done

if ! vcf cluster --help >/dev/null 2>&1; then
  log_error "'vcf cluster' command not available after ${PLUGIN_MAX}s — plugins may have failed to install"
  exit 7
fi

KUBECONFIG_FILE="./kubeconfig-${CLUSTER_NAME}.yaml"

if ! vcf cluster kubeconfig get "${CLUSTER_NAME}" --admin --export-file "${KUBECONFIG_FILE}"; then
  log_error "Failed to retrieve kubeconfig for cluster '${CLUSTER_NAME}'"
  exit 7
fi

export KUBECONFIG="${KUBECONFIG_FILE}"

# Verify connectivity to the VKS guest cluster (may take a moment after provisioning)
if ! wait_for_condition "VKS guest cluster API to become reachable" \
  300 10 \
  "kubectl get namespaces"; then
  log_error "Failed to connect to VKS guest cluster '${CLUSTER_NAME}' using kubeconfig at '${KUBECONFIG_FILE}'"
  exit 7
fi

log_success "Kubeconfig retrieved and saved to '${KUBECONFIG_FILE}' — connected to VKS guest cluster '${CLUSTER_NAME}'"

###############################################################################
# Phase 5b: Wait for Worker Nodes to Become Ready
###############################################################################

log_step "5b" "Waiting for worker nodes to become Ready"

WORKER_TIMEOUT="${WORKER_TIMEOUT:-600}"

if ! wait_for_condition "at least ${MIN_NODES} worker node(s) to become Ready" \
  "${WORKER_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ \$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready') -ge ${MIN_NODES} ]]"; then
  log_error "Worker nodes did not become Ready within ${WORKER_TIMEOUT}s"
  echo "Current node status:"
  kubectl get nodes -o wide 2>/dev/null || true
  exit 7
fi

kubectl get nodes -o wide
log_success "All worker nodes are Ready"

###############################################################################
# Phase 5c: Create Package Namespace
###############################################################################

log_step "5c" "Creating package namespace '${PACKAGE_NAMESPACE}'"

if kubectl get ns "${PACKAGE_NAMESPACE}" >/dev/null 2>&1; then
  log_success "Namespace '${PACKAGE_NAMESPACE}' already exists, skipping creation"
else
  kubectl create ns "${PACKAGE_NAMESPACE}"
  log_success "Namespace '${PACKAGE_NAMESPACE}' created"
fi

kubectl label ns "${PACKAGE_NAMESPACE}" \
  pod-security.kubernetes.io/enforce=privileged \
  --overwrite
log_success "Namespace '${PACKAGE_NAMESPACE}' labelled with privileged PodSecurity standard"

###############################################################################
# Phase 5d: Register Package Repository
###############################################################################

log_step "5d" "Registering package repository '${PACKAGE_REPO_NAME}'"

if vcf package repository list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "${PACKAGE_REPO_NAME}"; then
  log_success "Package repository '${PACKAGE_REPO_NAME}' already registered, skipping"
else
  vcf package repository add "${PACKAGE_REPO_NAME}" \
    --url "${PACKAGE_REPO_URL}" \
    --namespace "${PACKAGE_NAMESPACE}"

  if ! wait_for_condition "package repository '${PACKAGE_REPO_NAME}' to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package repository list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep '${PACKAGE_REPO_NAME}' | grep -qi 'reconcile'"; then
    log_error "Package repository '${PACKAGE_REPO_NAME}' did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 7
  fi
fi

log_success "Package repository setup complete"

###############################################################################
# Phase 5e: Install Cluster Autoscaler
###############################################################################

log_step "5e" "Installing Cluster Autoscaler package"

if vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "cluster-autoscaler"; then
  STATUS=$(vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep "cluster-autoscaler" || true)
  if echo "$STATUS" | grep -qi "reconcile failed\|error"; then
    echo "  Found failed cluster-autoscaler install, removing before re-install..."
    vcf package installed delete cluster-autoscaler -n "${PACKAGE_NAMESPACE}" --yes 2>/dev/null || true
    sleep 5
  else
    log_success "Cluster Autoscaler already installed and healthy, skipping"
  fi
fi

if ! vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "cluster-autoscaler"; then
  # Create values file with required cluster config and autoscaler tuning
  # Schema keys: clusterConfig, arguments (camelCase), extraArguments for CLI flags not in schema
  AUTOSCALER_VALUES=$(mktemp /tmp/autoscaler-values-XXXXXX.yaml)
  printf 'clusterConfig:\n  clusterName: %s\n  clusterNamespace: %s\narguments:\n  scaleDownUnneededTime: "%s"\n  scaleDownDelayAfterAdd: "%s"\n  scaleDownDelayAfterDelete: "%s"\n  extraArguments:\n  - "scale-down-utilization-threshold=%s"\n' \
    "${CLUSTER_NAME}" "${DYNAMIC_NS_NAME}" \
    "${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME}" \
    "${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD}" \
    "${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE}" \
    "${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD}" > "${AUTOSCALER_VALUES}"
  log_success "Autoscaler values: clusterName=${CLUSTER_NAME}, clusterNamespace=${DYNAMIC_NS_NAME}"
  log_success "Autoscaler tuning: scaleDownUnneededTime=${AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME}, scaleDownDelayAfterAdd=${AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD}, scaleDownUtilizationThreshold=${AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD}"

  vcf package install cluster-autoscaler \
    -p cluster-autoscaler.kubernetes.vmware.com \
    --values-file "${AUTOSCALER_VALUES}" \
    -n "${PACKAGE_NAMESPACE}"

  rm -f "${AUTOSCALER_VALUES}"

  if ! wait_for_condition "Cluster Autoscaler package to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'cluster-autoscaler' | grep -qi 'reconcile'"; then
    log_error "Cluster Autoscaler package did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 7
  fi
fi

log_success "Cluster Autoscaler installed and reconciled"

###############################################################################
# Phase 5f: Wait for Autoscaler Ready
###############################################################################

log_step "5f" "Waiting for Cluster Autoscaler deployment to be ready"

if ! wait_for_condition "Cluster Autoscaler deployment to be ready" \
  "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
  "kubectl get deployment -n kube-system cluster-autoscaler -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]' || kubectl get deployment -n '${PACKAGE_NAMESPACE}' cluster-autoscaler -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '[1-9]'"; then
  echo "  WARNING: Cluster Autoscaler deployment did not reach Ready within ${PACKAGE_TIMEOUT}s — autoscaling may not be active"
  kubectl get deployment -n kube-system cluster-autoscaler 2>/dev/null || true
else
  log_success "Cluster Autoscaler is ready (min=${MIN_NODES}, max=${MAX_NODES} worker nodes)"
fi

###############################################################################
# Phase 5g: Install cert-manager VKS Package (idempotent)
###############################################################################

log_step "5g" "Installing cert-manager VKS package"

if vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "cert-manager"; then
  log_success "cert-manager already installed, skipping"
else
  if ! vcf package install cert-manager \
    -p cert-manager.kubernetes.vmware.com \
    -n "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to install cert-manager package"
    exit 9
  fi

  if ! wait_for_condition "cert-manager package to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'cert-manager' | grep -qi 'reconcile'"; then
    log_error "cert-manager package did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 9
  fi
fi

log_success "cert-manager installed and reconciled"

###############################################################################
# Phase 5h: Install Contour VKS Package + envoy-lb Service (idempotent)
###############################################################################

log_step "5h" "Installing Contour VKS package"

if vcf package installed list --namespace "${PACKAGE_NAMESPACE}" 2>/dev/null | grep -q "contour"; then
  log_success "Contour already installed, skipping"
else
  if ! vcf package install contour \
    -p contour.kubernetes.vmware.com \
    -n "${PACKAGE_NAMESPACE}"; then
    log_error "Failed to install Contour package"
    exit 10
  fi

  if ! wait_for_condition "Contour package to reconcile" \
    "${PACKAGE_TIMEOUT}" "${POLL_INTERVAL}" \
    "vcf package installed list --namespace '${PACKAGE_NAMESPACE}' 2>/dev/null | grep 'contour' | grep -qi 'reconcile'"; then
    log_error "Contour package did not reconcile within ${PACKAGE_TIMEOUT}s"
    exit 10
  fi
fi

log_success "Contour installed and reconciled"

# Create envoy-lb LoadBalancer Service if not already present
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

# Ensure CoreDNS can resolve sslip.io hostnames (required for cert-manager HTTP-01 self-checks)
CURRENT_COREFILE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
if echo "${CURRENT_COREFILE}" | grep -q 'sslip.io'; then
  log_success "CoreDNS already has sslip.io forwarding rule, skipping"
else
  kubectl get configmap coredns -n kube-system -o json | python3 -c "
import json, sys
cm = json.load(sys.stdin)
corefile = cm['data']['Corefile']
sslip_block = 'sslip.io:53 {\n    forward . 8.8.8.8 1.1.1.1\n    cache 30\n}\n\n'
cm['data']['Corefile'] = sslip_block + corefile
json.dump(cm, sys.stdout)
" | kubectl apply -f - >/dev/null 2>&1
  kubectl rollout restart deployment/coredns -n kube-system >/dev/null 2>&1
  log_success "CoreDNS patched with sslip.io forwarding rule (→ 8.8.8.8, 1.1.1.1)"
  # Wait for CoreDNS to be ready after restart
  sleep 10
fi

###############################################################################
# Phase 5i: Create Let's Encrypt ClusterIssuers
###############################################################################

log_step "5i" "Creating Let's Encrypt ClusterIssuers"

if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
  log_success "ACME registration email: ${LETSENCRYPT_EMAIL}"
else
  echo "  ⚠ WARNING: LETSENCRYPT_EMAIL is empty — ACME registration may fail and no expiry notifications will be sent"
fi

# Create production ClusterIssuer
create_cluster_issuer "letsencrypt-prod" \
  "https://acme-v02.api.letsencrypt.org/directory" \
  "${LETSENCRYPT_EMAIL}"

# Create staging ClusterIssuer (for testing)
create_cluster_issuer "letsencrypt-staging" \
  "https://acme-staging-v02.api.letsencrypt.org/directory" \
  "${LETSENCRYPT_EMAIL}"

# Wait for the active ClusterIssuer to reach Ready status
CLUSTER_ISSUER_READY=false
if wait_for_condition "ClusterIssuer '${CLUSTER_ISSUER_NAME}' to reach Ready status" \
  120 "${POLL_INTERVAL}" \
  "check_cluster_issuer_ready '${CLUSTER_ISSUER_NAME}'"; then
  CLUSTER_ISSUER_READY=true
  log_success "ClusterIssuer '${CLUSTER_ISSUER_NAME}' is Ready"
else
  echo "  ⚠ WARNING: ClusterIssuer '${CLUSTER_ISSUER_NAME}' did not reach Ready within 120s — continuing without TLS"
fi

###############################################################################
# Phase 5j: Deploy Node DNS Patcher DaemonSet (sslip.io node-level resolution)
###############################################################################

if [[ "${USE_SSLIP_DNS}" == "true" ]]; then
  log_step "5j" "Deploying node DNS patcher DaemonSet for sslip.io resolution"
  deploy_node_dns_daemonset

  # Wait for DaemonSet to be ready (all desired pods scheduled and ready)
  if wait_for_condition "node-dns-patcher DaemonSet to be ready" \
    120 "${POLL_INTERVAL}" \
    "[[ \$(kubectl get daemonset node-dns-patcher -n kube-system -o jsonpath='{.status.numberReady}' 2>/dev/null) -gt 0 ]] && \
     [[ \$(kubectl get daemonset node-dns-patcher -n kube-system -o jsonpath='{.status.desiredNumberScheduled}') == \$(kubectl get daemonset node-dns-patcher -n kube-system -o jsonpath='{.status.numberReady}') ]]"; then
    log_success "Node DNS patcher DaemonSet is ready on all nodes"
  else
    echo "  ⚠ WARNING: Node DNS patcher DaemonSet not fully ready within 120s — continuing"
  fi

  # Allow time for the first DNS patch cycle to complete
  sleep 5
fi

###############################################################################
# Phase 6: Functional Validation Workload Deployment
###############################################################################

log_step 6 "Deploying functional validation workload (PVC, Deployment, LoadBalancer Service)"

# Generate and apply the functional test manifest
if ! cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vks-test-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${STORAGE_CLASS}
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vks-test-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vks-test-app
  template:
    metadata:
      labels:
        app: vks-test-app
    spec:
      securityContext:
        seccompProfile:
          type: RuntimeDefault
        runAsNonRoot: true
        runAsUser: 101
        fsGroup: 101
      containers:
      - name: nginx
        image: ${CONTAINER_REGISTRY}/vks-test-app:${IMAGE_TAG}
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
            - ALL
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: pvc-volume
          mountPath: /data
      volumes:
      - name: pvc-volume
        persistentVolumeClaim:
          claimName: vks-test-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: vks-test-lb
spec:
  type: LoadBalancer
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: vks-test-app
EOF
then
  log_error "Failed to apply functional validation workload manifest"
  exit 8
fi

# Wait for PVC to reach Bound status
if ! wait_for_condition "PVC 'vks-test-pvc' to reach Bound status" \
  "${PVC_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ \$(kubectl get pvc vks-test-pvc -o jsonpath='{.status.phase}') == 'Bound' ]]"; then
  log_error "PVC 'vks-test-pvc' did not reach Bound status within ${PVC_TIMEOUT}s"
  kubectl describe pvc vks-test-pvc
  exit 8
fi

log_success "PVC 'vks-test-pvc' is Bound"

# Wait for LoadBalancer external IP to be assigned
if ! wait_for_condition "LoadBalancer 'vks-test-lb' to receive external IP" \
  "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
  "[[ -n \$(kubectl get svc vks-test-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
  log_error "LoadBalancer 'vks-test-lb' did not receive an external IP within ${LB_TIMEOUT}s"
  kubectl get svc vks-test-lb -o wide
  exit 8
fi

EXTERNAL_IP=$(kubectl get svc vks-test-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
log_success "LoadBalancer 'vks-test-lb' assigned external IP: ${EXTERNAL_IP}"

# HTTP connectivity test (raw IP)
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://${EXTERNAL_IP}")
if [[ "${HTTP_STATUS}" != "200" ]]; then
  log_error "HTTP test failed — expected status 200 but got ${HTTP_STATUS} from http://${EXTERNAL_IP}"
  exit 8
fi

log_success "HTTP connectivity test passed — received status 200 from http://${EXTERNAL_IP}"

# --- sslip.io DNS + TLS (guarded by USE_SSLIP_DNS) ---
SSLIP_HOSTNAME=""
SSLIP_HTTP_URL=""
SSLIP_HTTPS_URL=""
TLS_READY=false

if [[ "${USE_SSLIP_DNS}" == "true" ]]; then
  # sslip.io hostname must use the Contour envoy-lb IP (not the test app's LB IP)
  # because Ingress traffic routes through Contour/Envoy, not directly to the backend
  if ! wait_for_condition "Envoy LoadBalancer 'envoy-lb' to receive external IP" \
    "${LB_TIMEOUT}" "${POLL_INTERVAL}" \
    "[[ -n \$(kubectl get svc envoy-lb -n '${CONTOUR_INGRESS_NAMESPACE}' -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null) ]]"; then
    echo "  ⚠ WARNING: Envoy LoadBalancer did not receive an external IP — skipping sslip.io"
  else
    CONTOUR_LB_IP=$(kubectl get svc envoy-lb -n "${CONTOUR_INGRESS_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    SSLIP_HOSTNAME=$(construct_sslip_hostname "${SSLIP_HOSTNAME_PREFIX}" "${CONTOUR_LB_IP}")
    SSLIP_HTTP_URL="http://${SSLIP_HOSTNAME}"
  log_success "sslip.io hostname: ${SSLIP_HOSTNAME} (via Contour LB ${CONTOUR_LB_IP})"

  # Determine TLS capability
  TLS_ENABLED=false
  if [[ "${CLUSTER_ISSUER_READY}" == "true" ]]; then
    TLS_ENABLED=true
  fi

  # Create Ingress (with or without TLS)
  create_ingress_with_tls "vks-test-sslip-ingress" "default" \
    "${SSLIP_HOSTNAME}" "vks-test-lb" 80 "${TLS_ENABLED}" "${CLUSTER_ISSUER_NAME}"

  log_success "sslip.io Ingress created (TLS: ${TLS_ENABLED})"

  # Wait for certificate if TLS is enabled
  if [[ "${TLS_ENABLED}" == "true" ]]; then
    if wait_for_certificate "vks-test-sslip-ingress-tls" "default" "${CERT_WAIT_TIMEOUT}"; then
      TLS_READY=true
      SSLIP_HTTPS_URL="https://${SSLIP_HOSTNAME}"
      log_success "TLS certificate is Ready"
    else
      echo "  ⚠ WARNING: TLS certificate not ready within ${CERT_WAIT_TIMEOUT}s — continuing with HTTP-only"
    fi
  fi

  # Verify HTTP connectivity via sslip.io hostname
  SSLIP_HTTP_STATUS=""
  SSLIP_HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${SSLIP_HTTP_URL}" 2>/dev/null) || true
  if [[ "${SSLIP_HTTP_STATUS}" == "200" ]]; then
    log_success "sslip.io HTTP test passed — received status 200 from ${SSLIP_HTTP_URL}"
  else
    echo "  ⚠ WARNING: sslip.io HTTP test returned status ${SSLIP_HTTP_STATUS:-000} from ${SSLIP_HTTP_URL}"
    echo "  Falling back to raw LoadBalancer IP for connectivity test"
  fi

  # Verify HTTPS connectivity if certificate is ready
  if [[ "${TLS_READY}" == "true" ]]; then
    SSLIP_HTTPS_STATUS=""
    SSLIP_HTTPS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "${SSLIP_HTTPS_URL}" 2>/dev/null) || true
    if [[ "${SSLIP_HTTPS_STATUS}" == "200" ]]; then
      log_success "sslip.io HTTPS test passed — received status 200 from ${SSLIP_HTTPS_URL}"
    else
      echo "  ⚠ WARNING: HTTPS test returned status ${SSLIP_HTTPS_STATUS:-000} from ${SSLIP_HTTPS_URL}"
    fi
  fi
  fi
fi

###############################################################################
# Success Summary
###############################################################################

echo ""
echo "============================================="
echo "  VCF 9 Deploy Cluster — Deployment Complete"
echo "============================================="
echo "  Cluster:    ${CLUSTER_NAME}"
echo "  Namespace:  ${DYNAMIC_NS_NAME}"
echo "  Kubeconfig: ${KUBECONFIG_FILE}"
echo "  External IP: ${EXTERNAL_IP}"
if [[ -n "${SSLIP_HOSTNAME}" ]]; then
echo "  sslip.io:   ${SSLIP_HTTP_URL}"
fi
if [[ -n "${SSLIP_HTTPS_URL}" ]]; then
echo "  HTTPS:      ${SSLIP_HTTPS_URL}"
fi
echo "============================================="
echo ""

exit 0
