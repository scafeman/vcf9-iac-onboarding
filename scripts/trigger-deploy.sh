#!/usr/bin/env bash
set -euo pipefail

# Companion trigger script for the deploy-vks GitHub Actions workflow.
# Sends a repository_dispatch event via the GitHub REST API.
#
# Required: --repo, --token, --project-name, --cluster-name, --namespace-prefix
# Optional: all infrastructure parameters (vpc-name, region, zone, etc.)
#           — if not provided, the workflow falls back to GitHub secrets or defaults.
#
# NOTE: Make this file executable with: chmod +x scripts/trigger-deploy.sh

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Trigger the deploy-vks GitHub Actions workflow via repository_dispatch.

Required:
  --repo              GitHub repository (OWNER/REPO)
  --token             GitHub PAT with repo scope
  --project-name      VCF Project name
  --cluster-name      VKS cluster name
  --namespace-prefix  Supervisor Namespace prefix (e.g., my-project-ns-)

Optional (override workflow defaults):
  --environment       Environment label (default: demo)
  --vpc-name          NSX VPC name
  --region-name       Region name
  --zone-name         Availability zone
  --resource-class    Namespace resource class
  --user-identity     SSO user identity for RBAC
  --content-library-id  vSphere Content Library ID
  --k8s-version       Kubernetes version
  --vm-class          VM class for worker nodes
  --storage-class     Storage class for PVCs
  --min-nodes         Autoscaler minimum worker nodes
  --max-nodes         Autoscaler maximum worker nodes
  --containerd-volume-size  Containerd data volume size per node
  --os-name           Node OS image name (photon or ubuntu, default: photon)
  --os-version        Node OS version (required for ubuntu, e.g., 24.04)
  --control-plane-replicas  Control plane node count: 1 (default) or 3 (HA)
  --node-pool-name    Worker node pool name (default: node-pool-01)
  --autoscaler-scale-down-unneeded-time     Time before underutilized node removal (default: 5m)
  --autoscaler-scale-down-delay-after-add   Cooldown after scale-up before scale-down (default: 5m)
  --autoscaler-scale-down-utilization-threshold  Node utilization threshold for scale-down (default: 0.5)
  --autoscaler-scale-down-delay-after-delete  Cooldown after node deletion before next scale-down (default: 10s)
  --vcfa-endpoint     VCFA hostname (no https://)
  --tenant-name       SSO tenant/organization

Example:
  $(basename "$0") \\
    --repo myorg/vcf9-iac \\
    --token ghp_xxxxxxxxxxxx \\
    --project-name my-project-01 \\
    --cluster-name my-project-01-clus-01 \\
    --namespace-prefix my-project-01-ns- \\
    --vpc-name region-us1-a-sample-vpc \\
    --region-name region-us1-a
EOF
}

# --- Defaults ---
REPO=""
TOKEN=""
PROJECT_NAME=""
CLUSTER_NAME=""
NAMESPACE_PREFIX=""
ENVIRONMENT=""
VPC_NAME=""
REGION_NAME=""
ZONE_NAME=""
RESOURCE_CLASS=""
USER_IDENTITY=""
CONTENT_LIBRARY_ID=""
K8S_VERSION=""
VM_CLASS=""
STORAGE_CLASS=""
MIN_NODES=""
MAX_NODES=""
CONTAINERD_VOLUME_SIZE=""
OS_NAME=""
OS_VERSION=""
CONTROL_PLANE_REPLICAS=""
NODE_POOL_NAME=""
AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME=""
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD=""
AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD=""
AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE=""
VCFA_ENDPOINT=""
TENANT_NAME=""

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)               REPO="$2"; shift 2 ;;
    --token)              TOKEN="$2"; shift 2 ;;
    --project-name)       PROJECT_NAME="$2"; shift 2 ;;
    --cluster-name)       CLUSTER_NAME="$2"; shift 2 ;;
    --namespace-prefix)   NAMESPACE_PREFIX="$2"; shift 2 ;;
    --environment)        ENVIRONMENT="$2"; shift 2 ;;
    --vpc-name)           VPC_NAME="$2"; shift 2 ;;
    --region-name)        REGION_NAME="$2"; shift 2 ;;
    --zone-name)          ZONE_NAME="$2"; shift 2 ;;
    --resource-class)     RESOURCE_CLASS="$2"; shift 2 ;;
    --user-identity)      USER_IDENTITY="$2"; shift 2 ;;
    --content-library-id) CONTENT_LIBRARY_ID="$2"; shift 2 ;;
    --k8s-version)        K8S_VERSION="$2"; shift 2 ;;
    --vm-class)           VM_CLASS="$2"; shift 2 ;;
    --storage-class)      STORAGE_CLASS="$2"; shift 2 ;;
    --min-nodes)          MIN_NODES="$2"; shift 2 ;;
    --max-nodes)          MAX_NODES="$2"; shift 2 ;;
    --containerd-volume-size) CONTAINERD_VOLUME_SIZE="$2"; shift 2 ;;
    --os-name)            OS_NAME="$2"; shift 2 ;;
    --os-version)         OS_VERSION="$2"; shift 2 ;;
    --control-plane-replicas) CONTROL_PLANE_REPLICAS="$2"; shift 2 ;;
    --node-pool-name)     NODE_POOL_NAME="$2"; shift 2 ;;
    --autoscaler-scale-down-unneeded-time) AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME="$2"; shift 2 ;;
    --autoscaler-scale-down-delay-after-add) AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD="$2"; shift 2 ;;
    --autoscaler-scale-down-utilization-threshold) AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD="$2"; shift 2 ;;
    --autoscaler-scale-down-delay-after-delete) AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE="$2"; shift 2 ;;
    --vcfa-endpoint)      VCFA_ENDPOINT="$2"; shift 2 ;;
    --tenant-name)        TENANT_NAME="$2"; shift 2 ;;
    -h|--help)            usage; exit 0 ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      usage >&2
      exit 1 ;;
  esac
done

# --- Validate required arguments ---
MISSING=()
[[ -z "$REPO" ]]             && MISSING+=("--repo")
[[ -z "$TOKEN" ]]            && MISSING+=("--token")
[[ -z "$PROJECT_NAME" ]]     && MISSING+=("--project-name")
[[ -z "$CLUSTER_NAME" ]]     && MISSING+=("--cluster-name")
[[ -z "$NAMESPACE_PREFIX" ]] && MISSING+=("--namespace-prefix")

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "Error: Missing required arguments: ${MISSING[*]}" >&2
  usage >&2
  exit 1
fi

# --- Build client_payload JSON ---
# Start with required fields, then add optional fields only if provided
PAYLOAD=$(cat <<EOF
{
  "project_name": "${PROJECT_NAME}",
  "cluster_name": "${CLUSTER_NAME}",
  "namespace_prefix": "${NAMESPACE_PREFIX}"
}
EOF
)

# Add optional fields using jq (only if non-empty)
add_field() {
  local key="$1" value="$2"
  if [[ -n "$value" ]]; then
    PAYLOAD=$(echo "$PAYLOAD" | jq --arg k "$key" --arg v "$value" '. + {($k): $v}')
  fi
}

add_field "environment"        "$ENVIRONMENT"
add_field "vpc_name"           "$VPC_NAME"
add_field "region_name"        "$REGION_NAME"
add_field "zone_name"          "$ZONE_NAME"
add_field "resource_class"     "$RESOURCE_CLASS"
add_field "user_identity"      "$USER_IDENTITY"
add_field "content_library_id" "$CONTENT_LIBRARY_ID"
add_field "k8s_version"        "$K8S_VERSION"
add_field "vm_class"           "$VM_CLASS"
add_field "storage_class"      "$STORAGE_CLASS"
add_field "min_nodes"          "$MIN_NODES"
add_field "max_nodes"          "$MAX_NODES"
add_field "containerd_volume_size" "$CONTAINERD_VOLUME_SIZE"
add_field "os_name"            "$OS_NAME"
add_field "os_version"         "$OS_VERSION"
add_field "control_plane_replicas" "$CONTROL_PLANE_REPLICAS"
add_field "node_pool_name"     "$NODE_POOL_NAME"
add_field "autoscaler_scale_down_unneeded_time" "$AUTOSCALER_SCALE_DOWN_UNNEEDED_TIME"
add_field "autoscaler_scale_down_delay_after_add" "$AUTOSCALER_SCALE_DOWN_DELAY_AFTER_ADD"
add_field "autoscaler_scale_down_utilization_threshold" "$AUTOSCALER_SCALE_DOWN_UTILIZATION_THRESHOLD"
add_field "autoscaler_scale_down_delay_after_delete" "$AUTOSCALER_SCALE_DOWN_DELAY_AFTER_DELETE"
add_field "vcfa_endpoint"      "$VCFA_ENDPOINT"
add_field "tenant_name"        "$TENANT_NAME"

# --- Send repository_dispatch event ---
DISPATCH_BODY=$(jq -n --argjson payload "$PAYLOAD" '{
  "event_type": "deploy-vks",
  "client_payload": $payload
}')

HTTP_RESPONSE=$(mktemp)
HTTP_STATUS=$(curl -s -o "$HTTP_RESPONSE" -w "%{http_code}" \
  -X POST \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "Content-Type: application/json" \
  "https://api.github.com/repos/${REPO}/dispatches" \
  -d "$DISPATCH_BODY")

if [[ "$HTTP_STATUS" != "204" ]]; then
  echo "Error: GitHub API returned HTTP ${HTTP_STATUS}" >&2
  cat "$HTTP_RESPONSE" >&2
  rm -f "$HTTP_RESPONSE"
  exit 2
fi

rm -f "$HTTP_RESPONSE"
echo "Workflow dispatched successfully."
echo "Parameters sent:"
echo "$PAYLOAD" | jq .
echo ""
echo "Monitor the run at: https://github.com/${REPO}/actions"
